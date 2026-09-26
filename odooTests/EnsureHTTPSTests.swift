//
//  EnsureHTTPSTests.swift
//  odooTests
//
//  `String.ensureHTTPS` recognises a scheme only at the very start of the string
//  (RFC 3986 `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) "://"`). A `://` inside a
//  path is ordinary path text — `ServerUrlInput` accepts `example.invalid/erp/a://b`
//  and every consumer (summary, repository, API client) must still get one `https://`.
//

import XCTest
@testable import odoo

final class EnsureHTTPSTests: XCTestCase {

    func test_ensureHTTPS_givenBareHostWithColonSlashInPath_prependsHttpsAndKeepsPath() {
        XCTAssertEqual("example.invalid/erp/a://b".ensureHTTPS, "https://example.invalid/erp/a://b")
    }

    func test_ensureHTTPS_givenHostPortWithColonSlashInPath_prependsHttps() {
        XCTAssertEqual("example.invalid:8069/erp/a://b".ensureHTTPS, "https://example.invalid:8069/erp/a://b")
    }

    func test_ensureHTTPS_givenSingleHttpsWithColonSlashInPath_isUnchanged() {
        XCTAssertEqual("https://example.invalid/erp/a://b".ensureHTTPS, "https://example.invalid/erp/a://b")
    }

    func test_ensureHTTPS_givenRepeatedHttpsWithColonSlashInPath_collapsesAndKeepsPath() {
        XCTAssertEqual("https://https://example.invalid/erp/a://b".ensureHTTPS, "https://example.invalid/erp/a://b")
    }

    func test_ensureHTTPS_givenHttpWithColonSlashInPath_upgradesAndKeepsPath() {
        XCTAssertEqual("http://example.invalid/erp/a://b".ensureHTTPS, "https://example.invalid/erp/a://b")
    }

    func test_ensureHTTPS_givenBareHost_prependsHttps() {
        XCTAssertEqual("odoo.example.com".ensureHTTPS, "https://odoo.example.com")
    }

    func test_ensureHTTPS_givenOtherLeadingScheme_passesThroughUnchanged() {
        XCTAssertEqual("ftp://files.example.com".ensureHTTPS, "ftp://files.example.com")
        XCTAssertEqual("svn+ssh://host.example/a://b".ensureHTTPS, "svn+ssh://host.example/a://b")
    }
}
