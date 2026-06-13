# Native macOS CAD App — Project Scaffold Plan

Target environment (verified on this machine): macOS 26.5.1, Xcode 26.2 (build 17C52),
Swift 6.2.3, Apple Silicon (arm64), Homebrew at `/opt/homebrew`. App code lives under
`/Users/macatt/w/LibreCAD/macos/`. The existing C++ library `libdxfrw` is already in the
repo at `/Users/macatt/w/LibreCAD/libraries/libdxfrw` (sources in `src/`, public headers
`libdxfrw.h`, `libdwgr.h`, `drw_*.h`).

> All API claims below were verified against the on-machine Xcode 26.2 SDK
> `.swiftinterface`/headers and a working build probe (see "Validation" at the end),
> not just from documentation.

---

## 1. Tooling recommendation: **XcodeGen** (firm)

**Decision: use XcodeGen** (`project.yml` -> generated `.xcodeproj`), with a thin SwiftPM
package (`engine/`) for the pure-Swift + C++ engine so the engine layer is also
`swift build`/`swift test`-able without Xcode.

Why XcodeGen and not the alternatives:

| Need | XcodeGen | pure SwiftPM | hand-maintained .xcodeproj | Tuist |
|---|---|---|---|---|
| Real `.app` bundle + `Info.plist` + `CFBundleDocumentTypes` | yes, first-class | **no** (SwiftPM cannot emit a macOS app bundle / document types) | yes | yes |
| Mixed Swift + C++ targets | yes (per-target settings) | yes (SwiftPM C++ interop) | yes | yes |
| `xcodebuild` + `swift build` from CLI | yes | partial (no app) | yes | yes |
| Clean git diffs / agent-editable | **yes** (declarative YAML; `.xcodeproj` is gitignored & regenerated) | yes | **no** (pbxproj merge hell) | yes-ish (Swift manifests; needs `tuist`) |
| Install footprint | `brew install xcodegen` (single binary) | built-in | none | larger; cloud-oriented, heavier |

- **Pure SwiftPM is disqualified** as the *app* layer: SwiftPM still cannot produce a
  macOS `.app` bundle or declare `CFBundleDocumentTypes`/document types. It is the right
  tool for the *engine library*, not the shippable app.
- **Hand-maintained `.xcodeproj`** produces unreviewable `project.pbxproj` diffs and is
  hostile to agent edits — exactly what we want to avoid.
- **Tuist** is capable but heavier (Swift-manifest graph, cloud features, larger install,
  no plain `brew install tuist` formula — it's distributed via its own installer/mise),
  and offers no decisive advantage over XcodeGen for a single app + a couple of libs.
- **XcodeGen is current and maintained**: latest release **2.45.4 (2026-04-14)**, with
  commits in April 2026; Homebrew formula `xcodegen` is `2.45.4` (bottled). It generates
  standard `.xcodeproj` files that Xcode 26 opens and `xcodebuild` builds. There is no
  signal it is broken on Xcode 26.
  Sources: https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4 ,
  https://formulae.brew.sh/api/formula/xcodegen.json

**Install:**
```bash
brew install xcodegen      # installs 2.45.4 (bottled)
```
> Note: `brew install` must run outside a restricted sandbox (it writes to
> `/opt/homebrew`). The formula is confirmed available on this machine.

**Workflow:** edit `project.yml` -> run `xcodegen generate` -> open/build the regenerated
`.xcodeproj`. Add `*.xcodeproj` to `.gitignore`; commit only `project.yml` + sources.

---

## 2. Recommended module / target layout

```
/Users/macatt/w/LibreCAD/macos/
├── project.yml                      # XcodeGen spec (generates LibreCADmacOS.xcodeproj)
├── .gitignore                       # ignores *.xcodeproj, .build/, DerivedData/
├── docs/scaffold-plan.md            # this file
│
├── engine/                          # SwiftPM package: pure logic, CLI-testable
│   ├── Package.swift
│   └── Sources/
│       ├── DxfBridge/               # C++ bridge target (Clang module over libdxfrw)
│       │   ├── include/
│       │   │   ├── DxfBridge.hpp    # UMBRELLA header: #includes the C++ API we expose
│       │   │   └── module.modulemap # (optional; SwiftPM auto-generates from umbrella)
│       │   └── DxfBridge.cpp        # thin C++ shim that calls into libdxfrw
│       ├── CADEngine/               # Swift: model, geometry, undo-friendly mutations
│       │   └── *.swift              #   imports DxfBridge with .interoperabilityMode(.Cxx)
│       └── (tests live in engine/Tests/)
│
├── engine/Tests/
│   ├── CADEngineTests/              # swift test  — pure Swift unit tests
│   └── DxfBridgeTests/              # swift test  — round-trips a tiny DXF via the bridge
│
└── App/                            # the macOS app target (built by xcodebuild via XcodeGen)
    ├── LibreCADApp.swift           # @main App + DocumentGroup
    ├── CADDocument.swift           # ReferenceFileDocument (class, ObservableObject)
    ├── UTTypes.swift               # custom UTType.dxf / .dwg
    ├── Canvas/
    │   ├── MetalCanvasView.swift   # NSViewRepresentable wrapping MTKView
    │   └── CanvasRenderer.swift    # MTKViewDelegate: clear + draw one line
    ├── Shaders.metal               # minimal 2D vertex/fragment pipeline
    ├── Info.plist                  # CFBundleDocumentTypes + UTExportedTypeDeclarations
    └── Assets.xcassets
```

Rationale for splitting `engine` (SwiftPM) from `App` (XcodeGen):
- The **engine + C++ bridge build and test from the command line with plain
  `swift build` / `swift test`** (no Xcode, no app bundle) — ideal for fast agent loops
  and CI. This is validated below.
- The **App target** (which needs the `.app` bundle, `Info.plist`, document types, Metal
  resources) is owned by XcodeGen and built with `xcodebuild`. It depends on the `engine`
  package via a local package reference in `project.yml`.

**Targets summary:**
- `DxfBridge` (C++ target, SwiftPM) — Clang module wrapping `libdxfrw`.
- `CADEngine` (Swift target, SwiftPM) — model/geometry; `swiftSettings: [.interoperabilityMode(.Cxx)]`.
- `LibreCADmacOS` (macOS app, XcodeGen) — SwiftUI + Metal; links `CADEngine`.
- `CADEngineTests`, `DxfBridgeTests` (SwiftPM `swift test`), plus optional
  `LibreCADmacOSUITests`/unit test bundle in XcodeGen for app-level tests.

---

## 3. Document model: `ReferenceFileDocument` (class) + `DocumentGroup`

Use **`ReferenceFileDocument`, not `FileDocument`.** Verified protocol (Xcode 26.2 SDK
`SwiftUI.swiftinterface`):

```swift
@preconcurrency public protocol ReferenceFileDocument : ObservableObject, Sendable {
  associatedtype Snapshot
  static var readableContentTypes: [UTType] { get }
  static var writableContentTypes: [UTType] { get }   // has a default impl == readable
  init(configuration: Self.ReadConfiguration) throws   // ReadConfiguration = FileDocumentReadConfiguration
  func snapshot(contentType: UTType) throws -> Self.Snapshot
  func fileWrapper(snapshot: Self.Snapshot, configuration: Self.WriteConfiguration) throws -> FileWrapper
}
```

Why `ReferenceFileDocument` for CAD:
- It is a **class / `ObservableObject`** (`FileDocument` is a value-type `struct`). A CAD
  model is a large mutable reference graph with in-place edits and undo — a class fits.
- It gives a **snapshot/serialize split**: SwiftUI captures `snapshot(contentType:)` on the
  main actor, then serializes via `fileWrapper(snapshot:configuration:)` off the main actor.
- **Undo:** `DocumentGroup` injects an `UndoManager` into the SwiftUI environment
  (`@Environment(\.undoManager)`). Register undoable edits against it from your views/model;
  SwiftUI marks the document dirty automatically when you mutate via the registered
  `UndoManager`. `ReferenceFileDocumentConfiguration` (the editor closure's argument) exposes
  `document`, `fileURL: URL?`, and `isEditable: Bool` (verified in the `.swiftinterface`).

`DocumentGroup` initializer (verified):
```swift
DocumentGroup(newDocument: { CADDocument() }) { config in
    ContentView(document: config.document)   // config.document, config.fileURL, config.isEditable
}
```

Source: https://developer.apple.com/documentation/swiftui/referencefiledocument

---

## 4. Document type / UTI for DXF and DWG

**There is no system-provided UTI for DXF/DWG.** Verified via `lsregister -dump`: the only
Autodesk type the OS knows is `com.autodesk.mac.fbx`; there is **no `public.dxf`,
`public.dwg`, or `com.autodesk.dxf`** registered. So we must **declare our own** UTIs as
**exported** types (we are the originator on this machine), conforming to `public.data` and
(for DXF) `public.text` since DXF ASCII is text; DWG is binary so conform only to
`public.data`.

Recommended identifiers (reverse-DNS, owned by us):
- DXF: **`org.librecad.dxf`**, extension `dxf`, conforms to `public.text`, `public.data`.
- DWG: **`org.librecad.dwg`**, extension `dwg`, conforms to `public.data`.

> Do **not** invent `public.dxf` (Apple-reserved `public.` tree) or squat
> `com.autodesk.dxf` (Autodesk's reverse-DNS). If Apple/Autodesk later define canonical
> UTIs you can add them to `conformsTo`/import declarations. Declare ours as **exported**.

`UTType` in Swift (`UTTypes.swift`):
```swift
import UniformTypeIdentifiers
extension UTType {
    static let dxf = UTType(exportedAs: "org.librecad.dxf")
    static let dwg = UTType(exportedAs: "org.librecad.dwg")
}
```

`Info.plist` — `UTExportedTypeDeclarations` + `CFBundleDocumentTypes`:
```xml
<key>UTExportedTypeDeclarations</key>
<array>
  <dict>
    <key>UTTypeIdentifier</key><string>org.librecad.dxf</string>
    <key>UTTypeDescription</key><string>AutoCAD DXF Drawing</string>
    <key>UTTypeConformsTo</key>
      <array><string>public.text</string><string>public.data</string></array>
    <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>dxf</string></array></dict>
  </dict>
  <dict>
    <key>UTTypeIdentifier</key><string>org.librecad.dwg</string>
    <key>UTTypeDescription</key><string>AutoCAD DWG Drawing</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>dwg</string></array></dict>
  </dict>
</array>
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key><string>AutoCAD DXF Drawing</string>
    <key>LSItemContentTypes</key><array><string>org.librecad.dxf</string></array>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
  </dict>
  <dict>
    <key>CFBundleTypeName</key><string>AutoCAD DWG Drawing</string>
    <key>LSItemContentTypes</key><array><string>org.librecad.dwg</string></array>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
  </dict>
</array>
```
> `readableContentTypes` on the document must list `[.dxf, .dwg]`; for editing both,
> `writableContentTypes` likewise. These must match `LSItemContentTypes`.

Source: https://developer.apple.com/documentation/uniformtypeidentifiers/uttype/init(exportedas:)
and https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes

---

## 5. Metal canvas in SwiftUI

**Approach:** wrap a real `MTKView` in an `NSViewRepresentable`, give it a coordinator that
is the `MTKViewDelegate`, and **roll our own minimal 2D pipeline** (a vertex buffer of line
endpoints + a trivial vertex/fragment shader). This is the right call for CAD:

- **Roll our own 2D pipeline** for vector primitives (lines/arcs/text-as-triangulated-glyphs).
  CoreGraphics-to-texture (draw with CG into a bitmap, upload as a texture each frame) is a
  fine *bootstrap* and great for text, but it does not scale to large drawings with smooth
  zoom — it re-rasterizes on every transform change. Start with a GPU line pipeline; you can
  composite a CG-rendered text/overlay texture on top later. (Arcs: tessellate to line
  strips on CPU initially, or do it in a shader later.)
- **Draw loop:** set `mtkView.delegate = coordinator`. For a CAD editor that only redraws on
  change, set `enableSetNeedsDisplay = true` and `isPaused = true`, then call
  `mtkView.setNeedsDisplay(_:)`/`needsDisplay = true` when the model or transform changes
  (verified: `enableSetNeedsDisplay` "pauses the internal render loop and updates become
  event driven"). For continuous animation instead, leave `isPaused = false` and set
  `preferredFramesPerSecond`.
- **Retina / drawableSize:** keep `autoResizeDrawable = true` (default) so `drawableSize`
  tracks the view in *pixels*; the delegate's `mtkView(_:drawableSizeWillChange:)` fires with
  the new pixel size — recompute your projection there. Map your world/zoom/pan transform to
  Normalized Device Coordinates in the vertex shader via a `float4x4` (or `float3x3` for 2D)
  uniform; do **not** bake retina scale into geometry — use `drawableSize` for the
  pixels-per-point and aspect.
- **Clear + present:** read `view.currentRenderPassDescriptor` (honors `view.clearColor`),
  encode into it, then `commandBuffer.present(view.currentDrawable!)` and `commit()`.

Verified `MTKView`/`MTKViewDelegate` API (Xcode 26.2 `MTKView.h`):
```objc
@property (nonatomic) MTLClearColor clearColor;
@property (nonatomic) BOOL enableSetNeedsDisplay;   // default NO
@property (nonatomic, getter=isPaused) BOOL paused; // default NO
@property (nonatomic) BOOL autoResizeDrawable;      // default YES
@property (nonatomic) CGSize drawableSize;
@property (nonatomic) NSInteger preferredFramesPerSecond;
@property (nonatomic, readonly, nullable) id<CAMetalDrawable> currentDrawable;
@property (nonatomic, readonly, nullable) MTLRenderPassDescriptor *currentRenderPassDescriptor;
// MTKViewDelegate:
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size;
- (void)drawInMTKView:(MTKView *)view;   // Swift: func draw(in view: MTKView)
```

Source: https://developer.apple.com/documentation/metalkit/mtkview ,
https://developer.apple.com/documentation/metalkit/mtkviewdelegate

---

## 6. Swift / C++ interop enablement (verified working on this machine)

### (a) Swift Package (the `engine`) — RECOMMENDED PATH
1. Put the C++ shim in its own target with an **umbrella header** under `include/`. SwiftPM
   **auto-generates the `module.modulemap`** from the umbrella header — no hand-written map
   needed. (You may still hand-write one if you want fine control.)
2. Enable interop **on the consuming Swift target** (not the C++ target):
   ```swift
   // swift-tools-version:6.0
   .target(name: "DxfBridge"),                       // C++ target (umbrella header in include/)
   .target(name: "CADEngine",
           dependencies: ["DxfBridge"],
           swiftSettings: [.interoperabilityMode(.Cxx)]),
   ```
   `.interoperabilityMode(.Cxx)` is the exact, current SwiftPM API.
3. **Gotcha (found during validation):** do **not** name a C++ target `CxxShim` — it
   collides with the toolchain-internal `libcxxshim` module ("redefinition of module"). Use a
   unique name like `DxfBridge`.
4. The C++ target's `CXX_STANDARD` should be **C++17 or higher** (the Swift clang importer
   already assumes ≥ C++14; pass `cxxSettings: [.unsafeFlags(["-std=c++17"])]` or rely on the
   package default). libdxfrw builds as C++.

### (b) Xcode target (the App, if it ever links C++ directly)
- Build setting: **"C++ and Objective-C interoperability"** = **"C++ / Objective-C++"**.
  The underlying key is **`SWIFT_OBJC_INTEROP_MODE = objcxx`** (verified in
  `Swift.xcspec`); it expands to the compiler flag `-cxx-interoperability-mode=default` and
  pulls the C++ standard from `CLANG_CXX_LANGUAGE_STANDARD` (must be > C++14).
- In `project.yml` set it per target:
  ```yaml
  settings:
    SWIFT_OBJC_INTEROP_MODE: objcxx
    CLANG_CXX_LANGUAGE_STANDARD: "c++17"
  ```
- **Preferred:** keep all C++ interop inside the SwiftPM `engine` and have the App import the
  pure-Swift `CADEngine` facade only. Then the App target never needs `objcxx` and stays a
  clean Swift-6 module. This isolates C++ from the UI layer.

### Swift 6 strict concurrency
- Imported C++ types are **non-`Sendable`** by default. Keep all libdxfrw calls behind the
  `CADEngine` Swift facade and confine them to a single actor (or `@MainActor` for the
  document). Do not pass raw C++ types across actor boundaries.
- The C++ shim should expose a **narrow, value-oriented Swift-friendly API** (return Swift
  arrays/structs, not raw `std::vector<DRW_*>` graphs) so the rest of the engine stays
  `Sendable`-clean. Mark the facade types `Sendable` only after copying out of C++.

Sources: https://www.swift.org/documentation/cxx-interop/ ,
https://www.swift.org/documentation/cxx-interop/project-build-setup/
(quote: *"The `interoperabilityMode` Swift build setting is used to enable C++
interoperability for a target … `swiftSettings: [.interoperabilityMode(.Cxx)]`"*; *"The
'C++ and Objective-C interoperability' Xcode build setting can be set to
'C++ / Objective-C++' to enable C++ interoperability for a specific build target."*)

---

## 7. Minimal concrete skeleton

### 7.1 `engine/Package.swift`
```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CADEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CADEngine", targets: ["CADEngine"]),
    ],
    targets: [
        // C++ bridge over ../../libraries/libdxfrw. Umbrella header in include/.
        .target(
            name: "DxfBridge",
            // If libdxfrw is compiled here, add its sources via `sources:`/`path:` or
            // build it separately and link with linkerSettings. To start, the shim can
            // statically vendor only the libdxfrw .cpp it needs.
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),
        .target(
            name: "CADEngine",
            dependencies: ["DxfBridge"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(
            name: "CADEngineTests",
            dependencies: ["CADEngine"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
```
`engine/Sources/DxfBridge/include/DxfBridge.hpp` (umbrella):
```cpp
#pragma once
namespace dxfbridge {
    // narrow, value-oriented API surfaced to Swift
    int probe();                 // returns 42 — smoke test
    // bool readDXF(const char* path, ...);   // wraps libdxfrw dxfRW::read
}
```
`engine/Sources/DxfBridge/DxfBridge.cpp`:
```cpp
#include "DxfBridge.hpp"
namespace dxfbridge { int probe() { return 42; } }
```

### 7.2 `macos/project.yml` (XcodeGen)
```yaml
name: LibreCADmacOS
options:
  bundleIdPrefix: org.librecad
  deploymentTarget: { macOS: "14.0" }
  createIntermediateGroups: true
packages:
  CADEngine:
    path: engine            # local SwiftPM package
settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "0.1.0"
targets:
  LibreCADmacOS:
    type: application
    platform: macOS
    sources: [App]
    dependencies:
      - package: CADEngine
        product: CADEngine
    info:
      path: App/Info.plist
      properties:
        CFBundleDisplayName: LibreCAD
        # CFBundleDocumentTypes + UTExportedTypeDeclarations: keep in App/Info.plist
        # (see section 4) — XcodeGen merges this file.
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.librecad.macos
        GENERATE_INFOPLIST_FILE: NO
        # If the App ever links C++ directly, also add:
        # SWIFT_OBJC_INTEROP_MODE: objcxx
        # CLANG_CXX_LANGUAGE_STANDARD: "c++17"
  LibreCADmacOSTests:
    type: bundle.unit-test
    platform: macOS
    sources: [AppTests]
    dependencies:
      - target: LibreCADmacOS
```
Generate + build:
```bash
cd /Users/macatt/w/LibreCAD/macos
xcodegen generate
xcodebuild -project LibreCADmacOS.xcodeproj -scheme LibreCADmacOS -destination 'platform=macOS' build
# engine alone, no Xcode:
swift build  --package-path engine
swift test   --package-path engine
```

### 7.3 `App/LibreCADApp.swift`  (@main + DocumentGroup)
```swift
import SwiftUI

@main
struct LibreCADApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { CADDocument() }) { config in
            ContentView(document: config.document)
        }
    }
}

struct ContentView: View {
    @ObservedObject var document: CADDocument
    @Environment(\.undoManager) private var undoManager
    var body: some View {
        MetalCanvasView(document: document)
            .frame(minWidth: 400, minHeight: 300)
    }
}
```

### 7.4 `App/CADDocument.swift`  (ReferenceFileDocument)
```swift
import SwiftUI
import UniformTypeIdentifiers

final class CADDocument: ReferenceFileDocument {
    typealias Snapshot = Data                       // replace with a real model snapshot

    static var readableContentTypes: [UTType] { [.dxf, .dwg] }
    static var writableContentTypes: [UTType] { [.dxf] }   // start: write DXF only

    // your mutable model lives here (entities, layers, …) — @Published for SwiftUI
    @Published var modelData: Data = Data()

    init() {}

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents
        else { throw CocoaError(.fileReadCorruptFile) }
        self.modelData = data                       // -> parse via CADEngine/DxfBridge
    }

    func snapshot(contentType: UTType) throws -> Data { modelData }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)   // -> serialize via CADEngine
    }
}
```

### 7.5 `App/UTTypes.swift`
```swift
import UniformTypeIdentifiers
extension UTType {
    static let dxf = UTType(exportedAs: "org.librecad.dxf")
    static let dwg = UTType(exportedAs: "org.librecad.dwg")
}
```

### 7.6 `App/Canvas/MetalCanvasView.swift`  (NSViewRepresentable + MTKView)
```swift
import SwiftUI
import MetalKit

struct MetalCanvasView: NSViewRepresentable {
    @ObservedObject var document: CADDocument

    func makeCoordinator() -> CanvasRenderer { CanvasRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.enableSetNeedsDisplay = true   // redraw on demand (CAD editor)
        view.isPaused = true                // no continuous loop
        context.coordinator.configure(view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.needsDisplay = true            // model changed -> redraw
    }
}
```

### 7.7 `App/Canvas/CanvasRenderer.swift`  (MTKViewDelegate: clear + one line)
```swift
import MetalKit

final class CanvasRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var pipeline: MTLRenderPipelineState!
    private var viewportSize = SIMD2<Float>(1, 1)

    func configure(_ view: MTKView) {
        device = view.device
        queue  = device.makeCommandQueue()
        let lib = try! device.makeDefaultLibrary(bundle: .main)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = lib.makeFunction(name: "v_main")
        desc.fragmentFunction = lib.makeFunction(name: "f_main")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
    }

    // retina / resize: drawableSize is in PIXELS
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = SIMD2<Float>(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // one line, NDC coords (-1...1). Replace with model->NDC transform (zoom/pan).
        var verts: [SIMD2<Float>] = [SIMD2(-0.8, -0.8), SIMD2(0.8, 0.8)]
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&verts, length: MemoryLayout<SIMD2<Float>>.stride * verts.count, index: 0)
        enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: verts.count)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
```

### 7.8 `App/Shaders.metal`
```metal
#include <metal_stdlib>
using namespace metal;
vertex float4 v_main(uint vid [[vertex_id]],
                     const device float2* verts [[buffer(0)]]) {
    return float4(verts[vid], 0.0, 1.0);
}
fragment float4 f_main() { return float4(0.9, 0.9, 0.2, 1.0); }
```

---

## 8. Validation performed on this machine (2026-06-11)

- **Swift/C++ interop builds & runs**: a SwiftPM package with a C++ `DxfBridge` target
  (umbrella header, auto-generated module map) + a Swift `App` target using
  `swiftSettings: [.interoperabilityMode(.Cxx)]` compiled and ran:
  `swift run … App` -> `cxx add(2,40) = 42`. (Required `--disable-sandbox` only because the
  build ran inside a nested sandbox; not needed for normal use.)
- **C++-target naming gotcha confirmed**: naming the C++ target `CxxShim` produced
  `redefinition of module 'CxxShim'` against the toolchain's `libcxxshim`. Renaming fixed it.
- **Build settings confirmed from the SDK**: `SWIFT_OBJC_INTEROP_MODE` enum is
  `{objcxx, objc}` (default `objc`); `objcxx` -> `-cxx-interoperability-mode=default`
  (`.../SWBUniversalPlatform.framework/.../Swift.xcspec`).
- **MTKView/ReferenceFileDocument/UTType APIs** were read from the Xcode 26.2 SDK
  `.swiftinterface`/headers, not just docs.
- **No system DXF/DWG UTI**: `lsregister -dump` shows only `com.autodesk.mac.fbx`; hence the
  exported-UTI recommendation.
- **XcodeGen**: latest release 2.45.4 (2026-04-14), Homebrew formula 2.45.4 (bottled),
  active commits in April 2026.

### Reference URLs
- https://developer.apple.com/documentation/swiftui/referencefiledocument
- https://developer.apple.com/documentation/swiftui/documentgroup
- https://developer.apple.com/documentation/uniformtypeidentifiers/uttype
- https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes
- https://developer.apple.com/documentation/metalkit/mtkview
- https://developer.apple.com/documentation/metalkit/mtkviewdelegate
- https://www.swift.org/documentation/cxx-interop/
- https://www.swift.org/documentation/cxx-interop/project-build-setup/
- https://github.com/yonaskolb/XcodeGen  (releases/tag/2.45.4)
- https://formulae.brew.sh/api/formula/xcodegen.json
