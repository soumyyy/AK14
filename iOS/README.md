# AK14 iPhone development build

Open `AK14iOS.xcodeproj` in Xcode. The project is generated from `Project.yml` with XcodeGen; regenerate it after changing target settings.

The app targets iOS 26 or newer. Its current installed flow imports selected Photos originals into app storage, analyzes them locally, creates a photos-only carousel, and lets you review, reorder, remove, save, or share slides. AI-assisted planning can be enabled in Story settings after configuring an HTTPS AK14 Worker URL and an invite token. The Worker is not deployed from this repository.

For an iPhone development install, sign in to Xcode with the Apple ID for your development team. Select that team for the `AK14iOS` target or pass `DEVELOPMENT_TEAM` to `xcodebuild`; Xcode must create a development provisioning profile for the bundle ID. The device must have Developer Mode enabled.

The simulator smoke test is:

```sh
xcodebuild -project AK14iOS.xcodeproj -scheme AK14iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  -only-testing:AK14iOSUITests/ImportGenerateReviewUITests \
  test CODE_SIGNING_ALLOWED=NO
```

The UI test exercises Photos permission, import, local generation, review, and opening the editor. It requires photos in the simulator's recent library. For development installs, do not put an OpenAI key or shared invite token in the app bundle.
