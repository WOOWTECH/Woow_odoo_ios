/**
 * geolocation_shim.js
 *
 * Injected at document start (WKUserScriptInjectionTime.atDocumentStart).
 * Overrides navigator.geolocation.getCurrentPosition so that all location
 * requests are brokered through the native WKScriptMessageHandler named
 * "requestLocation" rather than using the browser's built-in prompt.
 *
 * Native side resolves with __woowResolveGeo / __woowRejectGeo.
 *
 * Also provides dispatchMouseEventReal() — a helper that fires mousedown +
 * mouseup since OWL Dropdown ignores synthetic .click() events.
 */
(function () {
    'use strict';

    // Guard: only install once (e.g. if the script is somehow injected twice).
    if (window.__woowGeoShimInstalled) { return; }
    window.__woowGeoShimInstalled = true;

    // Map from requestId (UUID string) to {successCallback, errorCallback} so
    // that concurrent requests are resolved independently — no shared
    // pendingDecisionHandler race condition.
    var _pending = {};

    // ── Public callback entry points (called by native via evaluateJavaScript) ──

    /**
     * Called by native when location was successfully obtained.
     * @param {string} requestId - UUID matching the original postMessage.
     * @param {number} lat - Latitude in decimal degrees.
     * @param {number} lng - Longitude in decimal degrees.
     * @param {number} accuracy - Horizontal accuracy in metres.
     */
    window.__woowResolveGeo = function (requestId, lat, lng, accuracy) {
        var entry = _pending[requestId];
        if (!entry) { return; }
        delete _pending[requestId];
        var position = {
            coords: {
                latitude: lat,
                longitude: lng,
                accuracy: accuracy,
                altitude: null,
                altitudeAccuracy: null,
                heading: null,
                speed: null,
            },
            timestamp: Date.now(),
        };
        try { entry.success(position); } catch (e) { /* caller error — ignore */ }
    };

    /**
     * Called by native when location was denied or unavailable.
     * @param {string} requestId - UUID matching the original postMessage.
     * @param {number} code - GeolocationPositionError code (1=PERMISSION_DENIED, 2=UNAVAILABLE, 3=TIMEOUT).
     * @param {string} message - Human-readable description.
     */
    window.__woowRejectGeo = function (requestId, code, message) {
        var entry = _pending[requestId];
        if (!entry) { return; }
        delete _pending[requestId];
        var error = { code: code, message: message };
        try { if (entry.error) { entry.error(error); } } catch (e) { /* ignore */ }
    };

    // ── Override navigator.geolocation ──

    var _originalGeo = navigator.geolocation;

    var _shimmedGeo = {
        getCurrentPosition: function (successCallback, errorCallback, options) {
            // Generate a per-request UUID so concurrent calls are independent.
            var requestId = ([1e7] + -1e3 + -4e3 + -8e3 + -1e11)
                .replace(/[018]/g, function (c) {
                    return (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16);
                });

            _pending[requestId] = {
                success: successCallback,
                error: errorCallback || null,
            };

            try {
                webkit.messageHandlers.requestLocation.postMessage({
                    requestId: requestId,
                    origin: window.location.origin,
                });
            } catch (e) {
                // webkit.messageHandlers not available (e.g. plain browser) — fall back.
                delete _pending[requestId];
                if (_originalGeo) {
                    _originalGeo.getCurrentPosition(successCallback, errorCallback, options);
                } else if (errorCallback) {
                    errorCallback({ code: 2, message: 'Location unavailable' });
                }
            }
        },
        watchPosition: function (successCallback, errorCallback, options) {
            // watchPosition not needed for Odoo attendance — delegate to original if present.
            if (_originalGeo) {
                return _originalGeo.watchPosition(successCallback, errorCallback, options);
            }
            if (errorCallback) {
                errorCallback({ code: 2, message: 'watchPosition not supported in shim' });
            }
            return 0;
        },
        clearWatch: function (id) {
            if (_originalGeo) { _originalGeo.clearWatch(id); }
        },
    };

    try {
        Object.defineProperty(navigator, 'geolocation', {
            value: _shimmedGeo,
            configurable: true,
            enumerable: true,
        });
    } catch (e) {
        // Fallback for environments where the property is not configurable.
        navigator.geolocation = _shimmedGeo;
    }

    // ── dispatchMouseEventReal ──
    // OWL Dropdown components ignore synthetic click() events. Firing a real
    // mousedown + mouseup sequence triggers the OWL event handlers correctly.
    // Used by E2E tests via JSBridge.runInWebView.

    /**
     * Dispatches a real mousedown + mouseup sequence on the element, which OWL
     * correctly processes unlike a synthetic .click().
     */
    Element.prototype.dispatchMouseEventReal = function () {
        var el = this;
        el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
        el.dispatchEvent(new MouseEvent('mouseup',   { bubbles: true, cancelable: true, view: window }));
        el.dispatchEvent(new MouseEvent('click',     { bubbles: true, cancelable: true, view: window }));
    };

})();
