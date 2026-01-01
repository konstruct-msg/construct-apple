# Camera Permission Required

To use QR code scanning, you need to add camera permission to your Info.plist:

## Add to Info.plist (or Target Settings):

```xml
<key>NSCameraUsageDescription</key>
<string>Camera access is needed to scan QR codes for adding verified contacts</string>
```

## Or in Xcode:

1. Open project settings
2. Select your target (ConstructMessenger)
3. Go to Info tab
4. Add new entry:
   - Key: `Privacy - Camera Usage Description`
   - Value: `Camera access is needed to scan QR codes for adding verified contacts`

Without this permission, the app will crash when trying to access the camera.
