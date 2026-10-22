# SwiftUI iPad App

Open `IPadApp/IPadApp.xcodeproj` in Xcode 16 or later on a Mac.
Select the `IPadApp` scheme and an iPad simulator, then click Run. The deployment target is iPadOS 17 or later.
Only the initial screen and a Django server connection button are implemented.

## Server URL

- Debug: `http://localhost:8000`, configured in `IPadApp/Config/Debug.xcconfig`
- Personal Debug settings: copy `Local.xcconfig.example` to `Local.xcconfig` in the same directory and edit it
- Release: set a real HTTPS API URL in `Release.xcconfig`. It is currently empty, so requests display a configuration message

Because `//` starts a comment in xcconfig files, write URLs as `http:/$()/localhost:8000`.
This expands to `http://localhost:8000` in the built app.

To test on a physical iPad:

1. Connect the iPad and Mac to the same network.
2. Set the server URL in your personal `IPadApp/Config/Local.xcconfig` to the Mac's LAN IP address.
3. Add that IP to the backend's `DJANGO_ALLOWED_HOSTS` and start Django with `runserver 0.0.0.0:8000`.
4. Select your Team in Xcode's Signing & Capabilities settings and choose a unique bundle identifier if necessary.
5. Rebuild and run the app. Allow local network access and allow connections to the development server through the Mac's firewall.

The simulator does not require a developer Team or personal signing configuration.
`NSAllowsLocalNetworking` is enabled for local HTTP connections. Use HTTPS for the production server.

## Files

| File | Purpose |
| --- | --- |
| `IPadAppApp.swift` | App entry point |
| `ContentView.swift` | Initial screen and asynchronous connection status |
| `APIClient.swift` | URLSession requests, HTTP error handling, and JSON decoding |
| `Info.plist` | API URL injection and local network usage description |
| `Assets.xcassets` | Accent color and app icon placeholder |

`IPadApp` and `org.snuhcs.team13.ipadapp` are initial names.
Configure the final app name, icon, distribution signing, and production API URL later.
Handwriting input, handwriting recognition, authentication, and local storage are not implemented yet.
