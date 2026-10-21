import AppKit
import Carbon.HIToolbox
import CryptoKit
import Network
import SwiftUI

// Hotkey, changeable from the player. Defaults to ⌥` (Option + backtick).
UserDefaults.standard.register(defaults: ["hotKeyCode": kVK_ANSI_Grave, "hotKeyMods": optionKey, "hotKeyLabel": "⌥`"])
var shortcutLabel: String { UserDefaults.standard.string(forKey: "hotKeyLabel")! }

// Client ID from your app at developer.spotify.com, pasted in through the overlay and saved to
// ~/Library/Application Support/Overlay. The app's redirect URI must be exactly `redirectURI`.
let clientIDFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Overlay/client_id.txt")
var clientID: String { ((try? String(contentsOf: clientIDFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
let redirectURI = "http://127.0.0.1:8765/callback"
let scopes = "playlist-read-private playlist-read-collaborative user-modify-playback-state"

func spotify(_ script: String) -> String {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return "" }
    return NSAppleScript(source: "tell application \"Spotify\" to \(script)")?.executeAndReturnError(nil).stringValue ?? ""
}

// MARK: - Web API

struct Cover: Decodable { let url: String }
struct Playlist: Decodable, Identifiable { let id: String; let name: String; let uri: String; let images: [Cover]? }
struct Artist: Decodable { let name: String }
struct Album: Decodable { let name: String; let images: [Cover]? }
struct Track: Decodable { let name: String; let uri: String; let artists: [Artist]?; let album: Album?; let duration_ms: Int? }
struct Entry: Decodable { let item: Track? }
struct Page<T: Decodable>: Decodable { let items: [T?]; let next: String? }
struct Device: Decodable { let id: String?; let type: String }
struct Devices: Decodable { let devices: [Device] }
struct APIError: LocalizedError { let errorDescription: String? }

enum Auth {
    static let defaults = UserDefaults.standard
    static var refreshToken: String? { defaults.string(forKey: "refresh") }
    // Logins from before a scope was added count as logged out, so you get asked again.
    static var loggedIn: Bool {
        let granted = (defaults.string(forKey: "scope") ?? "").split(separator: " ")
        return refreshToken != nil && scopes.split(separator: " ").allSatisfy(granted.contains)
    }
    static var listener: NWListener?

    // PKCE login: open the browser, catch the redirect on a local port, swap the code for tokens.
    static func login(done: @escaping () -> Void) {
        let verifier = (0..<64).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! }.map(String.init).joined()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")

        listener?.cancel()
        guard let l = try? NWListener(using: .tcp, on: 8765) else { return }
        listener = l
        l.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let path = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ").dropFirst().first ?? ""
                let code = URLComponents(string: String(path))?.queryItems?.first { $0.name == "code" }?.value
                let body = code == nil ? "Login failed." : "Logged in. Press \(shortcutLabel) to go back to the overlay."
                conn.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n\(body)".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                guard let code else { return }
                l.cancel()
                Task { @MainActor in
                    try? await token(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI, "code_verifier": verifier])
                    done()
                }
            }
        }
        l.start(queue: .main)

        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge), .init(name: "scope", value: scopes),
        ]
        NSWorkspace.shared.open(url.url!)
    }

    static func logOut() {
        ["access", "expires", "refresh", "scope"].forEach(defaults.removeObject(forKey:))
    }

    static func token(_ params: [String: String]) async throws {
        var form = URLComponents()
        form.queryItems = (params.merging(["client_id": clientID]) { a, _ in a }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let json = try JSONSerialization.jsonObject(with: try await URLSession.shared.data(for: req).0) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String else { throw APIError(errorDescription: "Spotify login expired. Log in again.") }
        defaults.set(access, forKey: "access")
        defaults.set(Date().timeIntervalSince1970 + (json["expires_in"] as? Double ?? 3600) - 60, forKey: "expires")
        if let refresh = json["refresh_token"] as? String { defaults.set(refresh, forKey: "refresh") }
        if let scope = json["scope"] as? String { defaults.set(scope, forKey: "scope") }
    }

    static func accessToken() async throws -> String {
        if Date().timeIntervalSince1970 >= defaults.double(forKey: "expires"), let refresh = refreshToken {
            try await token(["grant_type": "refresh_token", "refresh_token": refresh])
        }
        return defaults.string(forKey: "access") ?? ""
    }
}

@discardableResult
func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
    var req = URLRequest(url: URL(string: path.hasPrefix("https") ? path : "https://api.spotify.com/v1/" + path)!)
    req.httpMethod = method
    req.setValue("Bearer \(try await Auth.accessToken())", forHTTPHeaderField: "Authorization")
    if let body {
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, resp) = try await URLSession.shared.data(for: req)
    switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
    case 200...299: return data
    case 403: throw APIError(errorDescription: "Spotify only shares songs from playlists you own or collaborate on.")
    case let code: throw APIError(errorDescription: "Spotify returned an error (\(code)).")
    }
}

func api<T: Decodable>(_ path: String) async throws -> T { try JSONDecoder().decode(T.self, from: try await request(path)) }

// MARK: - Model

final class Model: ObservableObject {
    @Published var info: [String] = []
    @Published var volume: Double = 50
    @Published var scrubPosition: Double?  // ms, while the progress bar is being dragged
    @Published var shortcut = shortcutLabel
    @Published var recordingShortcut = false
    @Published var showLibrary = false
    @Published var hasClientID = !clientID.isEmpty
    @Published var clientIDInput = ""
    @Published var loggedIn = Auth.loggedIn
    @Published var playlists: [Playlist] = []
    @Published var libraryMessage: String?
    @Published var open: Playlist?
    @Published var songs: [Track] = []
    @Published var songsMessage: String?
    var timer: Timer?

    func refresh() {
        let out = spotify("player state as string & linefeed & name of current track & linefeed & artist of current track & linefeed & artwork url of current track & linefeed & sound volume & linefeed & player position & linefeed & duration of current track & linefeed & spotify url of current track")
        info = out.components(separatedBy: "\n")
        if info.count == 8, let v = Double(info[4]) { volume = v }
    }

    // Update the screen straight away with what the click will do, then check Spotify a few times
    // over the next second, since it takes a moment to load a new track. Each check takes ~5 ms.
    func send(_ command: String) {
        if info.count == 8 {
            if command == "playpause" { info[0] = info[0] == "playing" ? "paused" : "playing" }
            if command.hasSuffix("track") { info[5] = "0" }
        }
        _ = spotify(command)
        for delay in [0.1, 0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.refresh() }
        }
    }

    func seek(editing: Bool) {
        guard !editing, let ms = scrubPosition else { return }
        _ = spotify("set player position to \(ms / 1000)")
        refresh()
        scrubPosition = nil
    }

    func setVolume(_ v: Double) {
        volume = v
        _ = spotify("set sound volume to \(Int(v))")
    }

    func showPlaylists() {
        showLibrary = true
        if loggedIn && playlists.isEmpty { loadPlaylists() }
    }

    func saveClientID() {
        let id = clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try FileManager.default.createDirectory(at: clientIDFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try id.write(to: clientIDFile, atomically: true, encoding: .utf8)
            hasClientID = !id.isEmpty
            libraryMessage = nil
        } catch { libraryMessage = "Couldn't save the Client ID: \(error.localizedDescription)" }
    }

    func login() {
        Auth.login { self.loggedIn = Auth.loggedIn; self.loadPlaylists() }
    }

    func logOut() {
        Auth.logOut()
        loggedIn = false
        playlists = []
        open = nil
    }

    func loadPlaylists() {
        Task { @MainActor in
            do {
                let page: Page<Playlist> = try await api("me/playlists?limit=50")
                playlists = page.items.compactMap { $0 }
                libraryMessage = playlists.isEmpty ? "No playlists yet." : nil
            } catch { libraryMessage = error.localizedDescription }
        }
    }

    func openPlaylist(_ p: Playlist) {
        open = p
        songs = []
        songsMessage = nil
        Task { @MainActor in
            var next: String? = "playlists/\(p.id)/items?limit=50"
            do {
                while let url = next, open?.id == p.id {
                    let page: Page<Entry> = try await api(url)
                    if open?.id == p.id { songs += page.items.compactMap { $0?.item } }
                    next = page.next
                }
            } catch { if open?.id == p.id { songsMessage = error.localizedDescription } }
        }
    }

    // Starting playback through the Web API, unlike AppleScript's `play track`, doesn't
    // bring Spotify's window forward and switch you to its screen.
    func play(_ t: Track, in p: Playlist) {
        let body: [String: Any] = ["context_uri": p.uri, "offset": ["uri": t.uri]]
        Task { @MainActor in
            do {
                try await request("me/player/play", method: "PUT", body: body)
            } catch {
                // No active device yet (Spotify open but idle): target this Mac's Spotify directly.
                let devices: Devices? = try? await api("me/player/devices")
                if let id = devices?.devices.first(where: { $0.type == "Computer" })?.id {
                    try? await request("me/player/play?device_id=\(id)", method: "PUT", body: body)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
        }
    }
}

// MARK: - Views

struct OverlayView: View {
    @ObservedObject var model: Model
    let close: () -> Void
    @State var copied = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture(perform: close)
            Group { if model.showLibrary { library } else { player } }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    var player: some View {
        VStack(spacing: 14) {
            HStack {
                Button(action: model.showPlaylists) { Label("Playlists", systemImage: "chevron.backward") }
                    .buttonStyle(Hit()).foregroundStyle(.secondary)
                Spacer()
                Button { model.recordingShortcut.toggle() } label: {
                    Label(model.recordingShortcut ? "Press keys…" : model.shortcut, systemImage: "keyboard")
                        .font(.callout)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(model.recordingShortcut ? 0.2 : 0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(Hit())
                .foregroundStyle(model.recordingShortcut ? .primary : .secondary)
                .help("Change the shortcut that opens the overlay")
            }
            if model.info.count == 8 {
                thumbnail(model.info[3], size: 280)
                Text(model.info[1]).font(.title3.bold()).lineLimit(1)
                Text(model.info[2]).foregroundStyle(.secondary).lineLimit(1)
                progressBar()
                controls(playSize: 48).font(.title2)
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                    Slider(value: Binding(get: { model.volume }, set: model.setVolume), in: 0...100).controlSize(.small).tint(.white)
                    Image(systemName: "speaker.wave.3.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                attribution(model.info[7])
            } else {
                Text("Spotify isn't playing").font(.title3).padding(.vertical, 40)
            }
        }
        .padding(28)
        .frame(width: 340)
    }

    // Times sit under the bar in the main player, and either side of it (inline) in the mini player.
    func progressBar(inline: Bool = false) -> some View {
        // Position is in seconds (with a locale-dependent decimal mark), duration in ms.
        let duration = Double(max(Int(model.info[6]) ?? 0, 1))
        let position = min(model.scrubPosition ?? (Double(model.info[5].replacingOccurrences(of: ",", with: ".")) ?? 0) * 1000, duration)
        let bar = Slider(value: Binding(get: { position }, set: { model.scrubPosition = $0 }), in: 0...duration, onEditingChanged: model.seek)
            .controlSize(.small).tint(.white)
        let elapsed = Text(time(Int(position))), total = Text(time(Int(duration)))
        return Group {
            if inline {
                HStack(spacing: 10) { elapsed; bar; total }
            } else {
                VStack(spacing: 4) {
                    bar
                    HStack { elapsed; Spacer(); total }
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    func controls(playSize: CGFloat) -> some View {
        HStack(spacing: playSize * 0.66) {
            Button { model.send("previous track") } label: { Image(systemName: "backward.fill") }
            Button { model.send("playpause") } label: {
                Image(systemName: model.info[0] == "playing" ? "pause.circle.fill" : "play.circle.fill").font(.system(size: playSize))
            }
            Button { model.send("next track") } label: { Image(systemName: "forward.fill") }
        }
        .buttonStyle(Hit())
    }

    // Compact now-playing bar under the playlist grid and inside an opened playlist.
    @ViewBuilder var miniPlayer: some View {
        if model.info.count == 8 {
            // Song on the left, controls and bar centred, and an equal-width spacer on the right so the
            // centre column really is centred.
            HStack(spacing: 16) {
                HStack(spacing: 12) {
                    thumbnail(model.info[3], size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.info[1]).lineLimit(1)
                        Text(model.info[2]).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: 170, alignment: .leading)
                VStack(spacing: 6) {
                    controls(playSize: 34)
                    progressBar(inline: true)
                }
                .frame(maxWidth: .infinity)
                Color.clear.frame(width: 170, height: 1)
            }
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    var library: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { model.showLibrary = false; model.open = nil } label: { Label("Now Playing", systemImage: "chevron.backward") }
                .buttonStyle(Hit()).foregroundStyle(.secondary)
            if !model.hasClientID || !model.loggedIn {
                connect.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Playlists").font(.title2.bold())
                if let message = model.libraryMessage { Text(message).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 140), spacing: 18)], spacing: 18) {
                        ForEach(model.playlists) { p in
                            Button { model.openPlaylist(p) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    thumbnail(p.images?.first?.url, size: 140)
                                    Text(p.name).font(.callout).lineLimit(1).frame(width: 140, alignment: .leading)
                                }
                            }
                            .buttonStyle(Hit())
                        }
                    }
                }
                miniPlayer
                attribution("spotify:")
            }
        }
        .padding(28)
        .frame(width: 720, height: 620, alignment: .topLeading)
        .overlay {
            if let p = model.open { songsPanel(p) }
        }
    }

    var connect: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text(model.hasClientID ? "Log in to Spotify" : "Connect Spotify").font(.title2.bold())
                Text(model.hasClientID ? "Opens your browser once. Press \(shortcutLabel) to come back when you're done."
                                       : "One-time setup so the overlay can see your playlists.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            if model.hasClientID {
                primaryButton("Log in", action: model.login)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    step(1, "Create an app with Web API ticked") {
                        Link("Open Spotify dashboard ↗", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                            .foregroundStyle(.white)
                    }
                    step(2, "Add this redirect URI") {
                        HStack {
                            Text(redirectURI).font(.callout.monospaced()).lineLimit(1)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(redirectURI, forType: .string)
                                copied = true
                            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                                .buttonStyle(Hit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                    step(3, "Paste its Client ID") {
                        TextField("Client ID", text: $model.clientIDInput)
                            .textFieldStyle(.plain).font(.callout.monospaced())
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            .onSubmit(model.saveClientID)
                    }
                }
                primaryButton("Continue", action: model.saveClientID)
                    .disabled(model.clientIDInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let message = model.libraryMessage { Text(message).font(.callout).foregroundStyle(.red) }
        }
        .frame(width: 380)
    }

    // Drawn by hand so it keeps its colour even though the overlay's app is never the active one.
    func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).foregroundStyle(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(Hit())
    }

    func step(_ n: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    func songsPanel(_ p: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { model.open = nil } label: { Label("Playlists", systemImage: "chevron.backward") }
                .buttonStyle(Hit()).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                thumbnail(p.images?.first?.url, size: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.name).font(.largeTitle.bold()).lineLimit(2)
                    Text(model.songsMessage ?? "\(model.songs.count) songs").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.songs.enumerated()), id: \.offset) { _, t in
                        Button { model.play(t, in: p) } label: {
                            HStack(spacing: 12) {
                                thumbnail(t.album?.images?.last?.url, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).lineLimit(1)
                                    Text(t.artists?.map(\.name).joined(separator: ", ") ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(t.album?.name ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: 200, alignment: .leading)
                                Text(time(t.duration_ms)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(Hit())
                    }
                }
            }
            miniPlayer
            attribution(p.uri)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.1))
    }

    func thumbnail(_ url: String?, size: CGFloat) -> some View {
        AsyncImage(url: URL(string: url ?? "")) { $0.resizable().scaledToFit() } placeholder: { Color.gray.opacity(0.2) }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 8 : 4))
    }

    // Spotify requires its logo next to its content and a link back to the Spotify app.
    func attribution(_ uri: String) -> some View {
        HStack {
            if let logo = Bundle.main.image(forResource: "spotify-logo") {
                Image(nsImage: logo).resizable().scaledToFit().frame(height: 22)
            }
            Spacer()
            Button("OPEN SPOTIFY") { NSWorkspace.shared.open(URL(string: uri)!) }
                .buttonStyle(Hit()).font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    func time(_ ms: Int?) -> String {
        let s = (ms ?? 0) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// Clicks land anywhere in a padded box around the label, not just on the glyphs.
struct Hit: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(8).contentShape(Rectangle()).padding(-8).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Window

// Private SkyLight calls (undocumented, so a future macOS could break them). A normal window belongs to
// a desktop and slides away with it during a Space swipe; putting the panel in its own always-on-top
// Space keeps it fixed on screen while the desktops slide underneath.
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSpaceCreate") func CGSSpaceCreate(_ cid: Int32, _ flag: Int32, _ options: CFDictionary?) -> UInt64
@_silgen_name("CGSSpaceSetAbsoluteLevel") func CGSSpaceSetAbsoluteLevel(_ cid: Int32, _ space: UInt64, _ level: Int32)
@_silgen_name("CGSShowSpaces") func CGSShowSpaces(_ cid: Int32, _ spaces: CFArray)
@_silgen_name("CGSAddWindowsToSpaces") func CGSAddWindowsToSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)
@_silgen_name("CGSRemoveWindowsFromSpaces") func CGSRemoveWindowsFromSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray?

let cid = CGSMainConnectionID()
let overlaySpace: UInt64 = {
    let space = CGSSpaceCreate(cid, 1, nil)
    CGSSpaceSetAbsoluteLevel(cid, space, 100)
    CGSShowSpaces(cid, [space] as CFArray)
    return space
}()

// Ordering a window front puts it back on the current desktop, so call this after every orderFront.
func pinToOverlaySpace(_ window: NSWindow) {
    let windows = [window.windowNumber] as CFArray
    let desktops = ((CGSCopySpacesForWindows(cid, 0x7, windows) as? [UInt64]) ?? []).filter { $0 != overlaySpace }
    CGSAddWindowsToSpaces(cid, windows, [overlaySpace] as CFArray)
    if !desktops.isEmpty { CGSRemoveWindowsFromSpaces(cid, windows, desktops as CFArray) }
}

final class Panel: NSPanel {
    var interceptKey: (NSEvent) -> Bool = { _ in false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, interceptKey(event) { return }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { true }

    // Menu-bar-only apps have no Edit menu, so ⌘V/⌘C/⌘X/⌘A need wiring up by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let actions: [String: Selector] = ["v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)),
                                           "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:))]
        if event.modifierFlags.contains(.command), let action = actions[event.charactersIgnoringModifiers ?? ""] {
            return NSApp.sendAction(action, to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var statusItem: NSStatusItem?
    var hotKey: EventHotKeyRef?
    var spaceChangedAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.level = .screenSaver
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: OverlayView(model: model) { [weak self] in self?.hide() })
        panel.interceptKey = { [weak self] in self?.handleKey($0) ?? false }
        // Clicking into another app closes the overlay. Swiping between Spaces also takes focus
        // away, so wait a moment and only hide if it wasn't a Space switch.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self, !self.panel.isKeyWindow, Date().timeIntervalSince(self.spaceChangedAt) > 1 else { return }
                self.hide()
            }
        }
        // The swipe hands focus to the new Space's app; take it back.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.spaceChangedAt = Date()
            self.panel.makeKeyAndOrderFront(nil)
            pinToOverlaySpace(self.panel)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = "♪"
        statusItem?.menu = NSMenu()
        statusItem?.menu?.addItem(withTitle: "Log Out of Spotify", action: #selector(logOut), keyEquivalent: "").target = self
        statusItem?.menu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.panel.isVisible ? me.hide() : me.show() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        registerHotKey()
    }

    func registerHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        let d = UserDefaults.standard
        RegisterEventHotKey(UInt32(d.integer(forKey: "hotKeyCode")), UInt32(d.integer(forKey: "hotKeyMods")),
                            EventHotKeyID(signature: 0x5350_4F56, id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }

    // Esc closes the overlay. While the shortcut button is waiting, Esc cancels instead, and the next
    // key press with ⌘, ⌥ or ⌃ becomes the new shortcut; other keys are ignored so typing can't clobber it.
    func handleKey(_ e: NSEvent) -> Bool {
        if Int(e.keyCode) == kVK_Escape {
            model.recordingShortcut ? (model.recordingShortcut = false) : hide()
            return true
        }
        guard model.recordingShortcut else { return false }
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return true }

        var mods = 0, label = ""
        if flags.contains(.control) { mods |= controlKey; label += "⌃" }
        if flags.contains(.option) { mods |= optionKey; label += "⌥" }
        if flags.contains(.shift) { mods |= shiftKey; label += "⇧" }
        if flags.contains(.command) { mods |= cmdKey; label += "⌘" }
        let key = e.charactersIgnoringModifiers ?? ""
        label += key == " " ? "Space" : key.uppercased()

        let d = UserDefaults.standard
        d.set(Int(e.keyCode), forKey: "hotKeyCode")
        d.set(mods, forKey: "hotKeyMods")
        d.set(label, forKey: "hotKeyLabel")
        registerHotKey()
        model.shortcut = label
        model.recordingShortcut = false
        return true
    }

    @objc func logOut() { model.logOut() }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        panel.setFrame(screen.frame, display: true)
        model.refresh()
        model.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.model.refresh() }
        panel.makeKeyAndOrderFront(nil)
        pinToOverlaySpace(panel)
    }

    func hide() {
        model.recordingShortcut = false
        model.timer?.invalidate()
        panel.orderOut(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
