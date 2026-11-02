import Combine
import SwiftUI
import UIKit

/// Apporo-only, mobile-first workspace for facilities teams.
/// It reads and creates Odoo Project tasks in the selected site/project.
struct FacilityDeskView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: FacilityDeskViewModel
    @State private var isShowingRequestForm = false

    init(serverUrl: String, sessionId: String?, onSessionExpired: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: FacilityDeskViewModel(
            serverUrl: serverUrl,
            sessionId: sessionId,
            onSessionExpired: onSessionExpired
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoadingProjects && viewModel.projects.isEmpty {
                    ProgressView(String(localized: "facility_loading"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.sessionId == nil {
                    emptyState(
                        symbol: "person.crop.circle.badge.exclamationmark",
                        title: "facility_session_required",
                        message: "facility_session_required_detail"
                    )
                } else if viewModel.projects.isEmpty {
                    emptyState(
                        symbol: "building.2",
                        title: "facility_no_projects",
                        message: viewModel.errorMessageKey ?? "facility_no_projects_detail"
                    )
                } else {
                    workList
                }
            }
            .navigationTitle(String(localized: "facility_desk_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingRequestForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(String(localized: "facility_new_request"))
                    .disabled(viewModel.selectedProject == nil || viewModel.isLoadingProjects)
                }
            }
            .task { await viewModel.loadProjects() }
            .sheet(isPresented: $isShowingRequestForm) {
                if let project = viewModel.selectedProject {
                    FacilityRequestForm(project: project) { title, details, priority in
                        await viewModel.createRequest(title: title, details: details, priority: priority)
                    }
                }
            }
        }
    }

    private var workList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "facility_desk_title"), systemImage: "building.2")
                        .font(.title3.weight(.semibold))
                    Text(String(localized: "facility_desk_intro"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker(String(localized: "facility_site_project"), selection: projectSelection) {
                        ForEach(viewModel.projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel(String(localized: "facility_site_project"))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                HStack {
                    Text(String(localized: "facility_recent_work"))
                        .font(.headline)
                    Spacer()
                    Button {
                        Task { await viewModel.refreshTasks() }
                    } label: {
                        Label(String(localized: "facility_refresh"), systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(String(localized: "facility_refresh"))
                    .disabled(viewModel.isLoadingTasks)
                }

                if let errorKey = viewModel.errorMessageKey {
                    Label {
                        Text(LocalizedStringKey(errorKey))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.isLoadingTasks && viewModel.tasks.isEmpty {
                    ProgressView(String(localized: "facility_loading"))
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if viewModel.tasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(String(localized: "facility_no_work"))
                            .font(.headline)
                        Text(String(localized: "facility_no_work_detail"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.tasks) { task in
                            FacilityTaskRow(task: task)
                        }
                    }
                }

                Text(String(localized: "facility_data_notice"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await viewModel.refresh() }
    }

    private var projectSelection: Binding<Int> {
        Binding(
            get: { viewModel.selectedProjectId ?? viewModel.projects.first?.id ?? 0 },
            set: { viewModel.selectProject(id: $0) }
        )
    }

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(title))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "facility_refresh")) {
                Task { await viewModel.loadProjects() }
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FacilityTaskRow: View {
    let task: FacilityTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                if let stage = task.stage {
                    Label(stage, systemImage: "circle.grid.2x2")
                }
                if let dueDate = task.dueDate {
                    Label(dueDate, systemImage: "calendar")
                }
                if task.isHighPriority {
                    Label(String(localized: "facility_high_priority"), systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct FacilityRequestForm: View {
    @Environment(\.dismiss) private var dismiss
    let project: FacilityProject
    let onSubmit: (String, String, FacilityRequestPriority) async -> Bool

    @State private var title = ""
    @State private var details = ""
    @State private var priority: FacilityRequestPriority = .standard
    @State private var isSubmitting = false
    @State private var showError = false
    @State private var showSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "facility_site_project")) {
                    Label(project.name, systemImage: "building.2")
                    Text(String(localized: "facility_request_project_help"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "facility_request_details")) {
                    TextField(String(localized: "facility_request_title"), text: $title)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityLabel(String(localized: "facility_request_title"))
                    TextField(String(localized: "facility_request_description"), text: $details, axis: .vertical)
                        .lineLimit(4...8)
                        .accessibilityLabel(String(localized: "facility_request_description"))
                    Picker(String(localized: "facility_request_priority"), selection: $priority) {
                        Text(String(localized: "facility_standard_priority")).tag(FacilityRequestPriority.standard)
                        Text(String(localized: "facility_high_priority")).tag(FacilityRequestPriority.high)
                    }
                }

                Section {
                    Text(String(localized: "facility_data_notice"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "facility_new_request"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Cancel")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(String(localized: "facility_submit_request"))
                        }
                    }
                    .disabled(isSubmitting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(String(localized: "facility_submit_failed_title"), isPresented: $showError) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(String(localized: "facility_submit_failed"))
            }
            .alert(String(localized: "facility_submit_success_title"), isPresented: $showSuccess) {
                Button(String(localized: "Done")) { dismiss() }
            } message: {
                Text(String(localized: "facility_submit_success"))
            }
        }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let succeeded = await onSubmit(
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            details.trimmingCharacters(in: .whitespacesAndNewlines),
            priority
        )
        if succeeded {
            showSuccess = true
        } else {
            showError = true
        }
    }
}

enum FacilityRequestPriority: String, Hashable, Sendable {
    case standard
    case high

    var odooValue: String { self == .high ? "1" : "0" }
}

@MainActor
final class FacilityDeskViewModel: ObservableObject {
    @Published private(set) var projects: [FacilityProject] = []
    @Published private(set) var tasks: [FacilityTask] = []
    @Published private(set) var selectedProjectId: Int?
    @Published private(set) var isLoadingProjects = false
    @Published private(set) var isLoadingTasks = false
    @Published private(set) var errorMessageKey: String?

    let serverUrl: String
    let sessionId: String?

    private let apiClient: OdooAPIClient
    private let onSessionExpired: () -> Void
    private var taskLoadID = UUID()

    init(
        serverUrl: String,
        sessionId: String?,
        apiClient: OdooAPIClient = OdooAPIClient(),
        onSessionExpired: @escaping () -> Void
    ) {
        self.serverUrl = serverUrl
        self.sessionId = sessionId
        self.apiClient = apiClient
        self.onSessionExpired = onSessionExpired
    }

    var selectedProject: FacilityProject? {
        projects.first(where: { $0.id == selectedProjectId })
    }

    func loadProjects() async {
        guard !isLoadingProjects else { return }
        guard let sessionId else {
            errorMessageKey = "facility_session_required_detail"
            return
        }
        isLoadingProjects = true
        errorMessageKey = nil
        defer { isLoadingProjects = false }

        do {
            let records = try await apiClient.searchReadInSession(
                serverUrl: serverUrl,
                sessionId: sessionId,
                model: "project.project",
                fields: ["id", "name", "active"],
                domain: [["active", "=", true]],
                limit: 80,
                sort: "name asc"
            )
            projects = records.compactMap { record in
                guard let id = record["id"] as? Int,
                      let name = record["name"] as? String,
                      !name.isEmpty else { return nil }
                return FacilityProject(id: id, name: name)
            }
            if !projects.contains(where: { $0.id == selectedProjectId }) {
                selectedProjectId = projects.first?.id
            }
            if selectedProjectId != nil {
                await refreshTasks()
            }
        } catch {
            handle(error)
            projects = []
            tasks = []
        }
    }

    func refresh() async {
        if projects.isEmpty {
            await loadProjects()
        } else {
            await refreshTasks()
        }
    }

    func refreshTasks() async {
        guard let projectId = selectedProjectId, let sessionId else { return }
        let loadID = UUID()
        taskLoadID = loadID
        isLoadingTasks = true
        errorMessageKey = nil
        defer {
            if taskLoadID == loadID { isLoadingTasks = false }
        }

        do {
            let records = try await apiClient.searchReadInSession(
                serverUrl: serverUrl,
                sessionId: sessionId,
                model: "project.task",
                fields: ["id", "name", "stage_id", "priority", "date_deadline"],
                domain: [["project_id", "=", projectId], ["active", "=", true]],
                limit: 30,
                sort: "write_date desc"
            )
            guard taskLoadID == loadID, selectedProjectId == projectId else { return }
            tasks = records.compactMap(FacilityTask.init(record:))
        } catch {
            guard taskLoadID == loadID, selectedProjectId == projectId else { return }
            handle(error)
            tasks = []
        }
    }

    func selectProject(id: Int) {
        guard selectedProjectId != id, projects.contains(where: { $0.id == id }) else { return }
        // Invalidate immediately, before the newly scheduled load starts.
        taskLoadID = UUID()
        selectedProjectId = id
        tasks = []
        errorMessageKey = nil
        Task { await refreshTasks() }
    }

    func createRequest(title: String, details: String, priority: FacilityRequestPriority) async -> Bool {
        guard let sessionId, let project = selectedProject,
              !title.isEmpty, !details.isEmpty else { return false }

        let prefix = String(localized: "facility_request_prefix")
        let html = Self.requestDescription(projectName: project.name, details: details)
        do {
            let result = try await apiClient.callKwInSession(
                serverUrl: serverUrl,
                sessionId: sessionId,
                model: "project.task",
                method: "create",
                args: [[
                    "name": "\(prefix): \(title)",
                    "project_id": project.id,
                    "description": html,
                    "priority": priority.odooValue
                ]]
            )
            guard result as? Int != nil else {
                errorMessageKey = "facility_submit_failed"
                return false
            }
            await refreshTasks()
            return true
        } catch {
            handle(error)
            if errorMessageKey == nil { errorMessageKey = "facility_submit_failed" }
            return false
        }
    }

    private func handle(_ error: Error) {
        if let apiError = error as? OdooAPIError, apiError == .sessionExpired {
            errorMessageKey = "facility_session_expired"
            onSessionExpired()
        } else {
            // Do not surface server debug details or account data in the UI.
            errorMessageKey = "facility_load_failed"
        }
    }

    private static func requestDescription(projectName: String, details: String) -> String {
        let project = escapeHTML(projectName)
        let paragraphs = escapeHTML(details)
            .components(separatedBy: .newlines)
            .map { "<p>\($0.isEmpty ? "<br>" : $0)</p>" }
            .joined()
        return "<p><strong>\(String(localized: "facility_site_project")):</strong> \(project)</p>\(paragraphs)"
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

struct FacilityProject: Identifiable, Equatable {
    let id: Int
    let name: String
}

struct FacilityTask: Identifiable, Equatable {
    let id: Int
    let title: String
    let stage: String?
    let dueDate: String?
    let isHighPriority: Bool

    init?(record: [String: Any]) {
        guard let id = record["id"] as? Int,
              let title = record["name"] as? String else { return nil }
        self.id = id
        self.title = title
        if let stage = record["stage_id"] as? [Any], stage.count > 1 {
            self.stage = stage[1] as? String
        } else {
            self.stage = nil
        }
        self.dueDate = record["date_deadline"] as? String
        self.isHighPriority = (record["priority"] as? String) == "1"
    }
}
