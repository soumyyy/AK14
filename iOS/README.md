# AK14 iPhone development build

Open `iOS/AK14iOS.xcodeproj` in Xcode. The project is generated from `iOS/Project.yml` with XcodeGen; regenerate it after changing target settings.

The app targets iOS 26 or newer. It imports selected Photos originals into app storage, analyzes them locally, and lets you review, reorder, remove, save, or share generated slides. AI-assisted planning starts on and needs a one-time invite token in Story settings; the HTTPS Worker URL is prefilled. The token is stored in the device Keychain, and the app explains that small thumbnails and short descriptions are sent for planning. Full-resolution originals stay on the device. The Worker is deployed, but its model-assisted flow has not yet been verified on an iPhone.

For an iPhone development install, sign in to Xcode with the Apple ID for your development team. Select that team for the `AK14iOS` target or pass `DEVELOPMENT_TEAM` to `xcodebuild`; Xcode must create a development provisioning profile for the bundle ID. The device must have Developer Mode enabled.

The simulator smoke test is:

```sh
xcodebuild -project AK14iOS.xcodeproj -scheme AK14iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  -only-testing:AK14iOSUITests/ImportGenerateReviewUITests \
  test CODE_SIGNING_ALLOWED=NO
```

The UI test exercises Photos permission, import, local generation, review, and opening the editor. It requires photos in the simulator's recent library. For development installs, do not put an OpenAI key or shared invite token in the app bundle.
