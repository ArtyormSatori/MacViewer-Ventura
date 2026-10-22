import Foundation
import Testing
@testable import MacViewer

struct MeshDefaultsTests {
    @Test("Empty or missing server addresses fall back to the default server")
    func fallback() {
        #expect(MeshDefaults.resolveServerURL(nil) == MeshDefaults.serverURL)
        #expect(MeshDefaults.resolveServerURL("") == MeshDefaults.serverURL)
        #expect(MeshDefaults.resolveServerURL("   ") == MeshDefaults.serverURL)
    }

    @Test("Full URLs are kept as entered")
    func fullURLs() {
        #expect(MeshDefaults.resolveServerURL("http://127.0.0.1:18734")
                == URL(string: "http://127.0.0.1:18734"))
        #expect(MeshDefaults.resolveServerURL("https://mesh.example.com")
                == URL(string: "https://mesh.example.com"))
    }

    @Test("Bare host and host:port get an http scheme")
    func bareHosts() {
        #expect(MeshDefaults.resolveServerURL("vega.lan:4821") == URL(string: "http://vega.lan:4821"))
        #expect(MeshDefaults.resolveServerURL("example.com") == URL(string: "http://example.com"))
        #expect(MeshDefaults.resolveServerURL("  192.168.1.10:9000 ")
                == URL(string: "http://192.168.1.10:9000"))
    }

    @Test("Unusable addresses fall back instead of producing a broken client")
    func unusable() {
        #expect(MeshDefaults.resolveServerURL("ftp://example.com") == MeshDefaults.serverURL)
        #expect(MeshDefaults.resolveServerURL("http://") == MeshDefaults.serverURL)
    }

    // MARK: Default constant + override resolution (redesign §3.1)

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MeshDefaultsTests-\(UUID().uuidString)")!
    }

    @Test("The built-in default server is the project address from the redesign spec")
    func defaultConstant() {
        #expect(MeshDefaults.serverURL == URL(string: "https://tavis.loc.cc"))
    }

    @Test("No stored value at all resolves to the default server")
    func noOverrideIsDefault() {
        let defaults = makeDefaults()
        #expect(MeshDefaults.configuration(in: defaults) == .default)
        #expect(MeshDefaults.configuration(in: defaults).url == MeshDefaults.serverURL)
        #expect(!MeshDefaults.configuration(in: defaults).isCustom)
    }

    @Test("A legacy value equal to the old loopback development default is a migrated placeholder, not an override")
    func legacyLoopbackMigratesToDefault() {
        for raw in ["http://127.0.0.1:18734", "127.0.0.1:18734", "localhost:18734",
                    "http://localhost:18734"] {
            let defaults = makeDefaults()
            defaults.set(raw, forKey: MeshDefaults.serverAddressKey)
            #expect(MeshDefaults.configuration(in: defaults) == .default,
                    "legacy value \(raw) must not pin the user to localhost")
        }
    }

    @Test("A legacy custom address from the old Settings field is respected")
    func legacyCustomRespected() {
        let defaults = makeDefaults()
        defaults.set("mesh.example.com:9000", forKey: MeshDefaults.serverAddressKey)
        #expect(MeshDefaults.configuration(in: defaults)
                == .custom(URL(string: "http://mesh.example.com:9000")!))
    }

    @Test("A deliberate override wins over the legacy value — including a deliberate loopback")
    func overridePrecedence() {
        let defaults = makeDefaults()
        defaults.set("mesh.example.com:9000", forKey: MeshDefaults.serverAddressKey)
        defaults.set("http://vega.lan:8734", forKey: MeshDefaults.serverOverrideKey)
        #expect(MeshDefaults.configuration(in: defaults)
                == .custom(URL(string: "http://vega.lan:8734")!))
        // The same loopback the migration rule forgives in the legacy
        // key is a real choice when stored as a deliberate override.
        defaults.set("http://127.0.0.1:18734", forKey: MeshDefaults.serverOverrideKey)
        #expect(MeshDefaults.configuration(in: defaults)
                == .custom(MeshDefaults.legacyDevelopmentServerURL))
    }

    @Test("Setting a custom server writes both keys; resetting clears both")
    func setAndReset() {
        let defaults = makeDefaults()
        let url = URL(string: "http://vega.lan:8734")!
        MeshDefaults.setCustomServer(url, in: defaults)
        #expect(defaults.string(forKey: MeshDefaults.serverOverrideKey) == url.absoluteString)
        #expect(defaults.string(forKey: MeshDefaults.serverAddressKey) == url.absoluteString)
        #expect(MeshDefaults.configuration(in: defaults) == .custom(url))
        MeshDefaults.useDefaultServer(in: defaults)
        #expect(defaults.string(forKey: MeshDefaults.serverOverrideKey) == nil)
        #expect(defaults.string(forKey: MeshDefaults.serverAddressKey) == nil)
        #expect(MeshDefaults.configuration(in: defaults) == .default)
    }

    @Test("An unusable override falls back to a usable legacy value; unusable values everywhere mean default")
    func unusableShapesFallThrough() {
        let defaults = makeDefaults()
        defaults.set("ftp://bad.example", forKey: MeshDefaults.serverOverrideKey)
        defaults.set("mesh.example.com:9000", forKey: MeshDefaults.serverAddressKey)
        #expect(MeshDefaults.configuration(in: defaults)
                == .custom(URL(string: "http://mesh.example.com:9000")!))
        defaults.set("ht tp://broken", forKey: MeshDefaults.serverAddressKey)
        #expect(MeshDefaults.configuration(in: defaults) == .default)
    }

    @Test("The migration boundary is exact: same host, wrong port or wrong scheme is a real custom server")
    func legacyBoundaryIsExact() {
        for raw in ["127.0.0.1:9999", "https://127.0.0.1:18734", "localhost:8734"] {
            let defaults = makeDefaults()
            defaults.set(raw, forKey: MeshDefaults.serverAddressKey)
            #expect(MeshDefaults.configuration(in: defaults).isCustom,
                    "legacy value \(raw) is not the development placeholder and must be respected")
        }
    }

    @Test("Strict normalization reports unusable input as nil instead of falling back")
    func normalizeStrict() {
        #expect(MeshDefaults.normalizeServerAddress(nil) == nil)
        #expect(MeshDefaults.normalizeServerAddress("   ") == nil)
        #expect(MeshDefaults.normalizeServerAddress("ftp://example.com") == nil)
        #expect(MeshDefaults.normalizeServerAddress("http://") == nil)
        #expect(MeshDefaults.normalizeServerAddress("vega.lan:8734")
                == URL(string: "http://vega.lan:8734"))
        #expect(MeshDefaults.normalizeServerAddress("https://mesh.example.com")
                == URL(string: "https://mesh.example.com"))
    }
}
