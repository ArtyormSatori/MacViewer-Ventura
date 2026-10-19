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
}
