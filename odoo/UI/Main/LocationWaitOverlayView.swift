import UIKit

/// Covers the page while a clock-in waits for its location.
///
/// It takes touches from the moment the wait starts. The spinner only fades in after a short
/// delay, so a fix that arrives immediately does not flash anything on screen.
final class LocationWaitOverlayView: UIView {

    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isHidden = true
        accessibilityIdentifier = "location-wait-overlay"

        label.text = String(localized: "location_waiting")
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 12
        card.alpha = 0
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        addSubview(card)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setWaiting(_ waiting: Bool) {
        card.layer.removeAllAnimations()
        isHidden = !waiting
        accessibilityViewIsModal = waiting
        if waiting {
            spinner.startAnimating()
            card.alpha = 0
            UIView.animate(withDuration: 0.2, delay: 0.3) { self.card.alpha = 1 }
            UIAccessibility.post(notification: .announcement, argument: label.text)
        } else {
            spinner.stopAnimating()
            card.alpha = 0
        }
    }
}
