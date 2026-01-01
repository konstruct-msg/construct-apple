# Camera Testing Guide

## Overview
QRScannerView now includes comprehensive testing and debugging tools to help diagnose camera issues.

## Features

### 1. Debug Panel
Access detailed camera status information in real-time.

**How to use:**
1. Open QR Scanner
2. Tap the ℹ️ icon in top-right corner
3. View debug information:
   - **Session Ready**: Shows if AVCaptureSession is initialized
   - **Permission**: Camera permission status
   - **Device**: Simulator vs Real Device
   - **Camera**: Camera device name

### 2. Test Mode (Automatic on Simulator)
Simulates QR code scanning without a real camera.

**Automatically enabled on:**
- ✅ iOS Simulator (no camera available)

**Manually enable on real device:**
Edit `QRScannerView.swift` line 26:
```swift
return false  // Change to true
```

### 3. Test Scan Button
Simulates scanning a valid QR code.

**How to use:**
1. Open Debug Panel (ℹ️ icon)
2. Tap "Test Scan" button
3. Generates random test contact:
   ```
   construct://add-contact?id=<UUID>&username=test_user_XXX
   ```

## Debugging Camera Issues

### Issue: Black Screen on Real Device

**Step 1: Check Debug Panel**
Open debug panel and check:

| Status | Meaning | Fix |
|--------|---------|-----|
| Session Ready: ❌ No | Camera session failed to initialize | Check console logs for errors |
| Permission: ❌ Denied | Camera access denied | Open Settings → Privacy → Camera → Enable for app |
| Permission: ⏳ Not Determined | Permission not asked yet | App should auto-request |

**Step 2: Check Console Logs**
Look for these messages in Xcode console (Cmd+Shift+Y):

✅ **Success:**
```
✅ Camera permission granted
✅ Camera session ready
✅ Camera session started
📱 makeUIView called - creating camera view
✅ Adding preview layer to view
```

❌ **Failure:**
```
❌ No video capture device available
❌ Camera permission denied
❌ Cannot add video input
❌ getPreviewLayer returned nil
```

**Step 3: Verify Info.plist**
Check that camera permission is set:
```xml
<key>NSCameraUsageDescription</key>
<string>Camera access is needed to scan QR codes...</string>
```

Or in Xcode:
- Target Settings → Info
- Check for "Privacy - Camera Usage Description"

### Issue: Permission Alert Not Showing

**Possible causes:**
1. Permission already denied in Settings
   - Fix: Settings → Privacy → Camera → Enable
2. iOS cached denial
   - Fix: Delete app and reinstall
3. Running on simulator
   - Fix: Use Test Mode instead

### Issue: Camera Works but Can't Scan QR

**Check:**
1. QR code is visible and in focus
2. Sufficient lighting
3. QR code format is correct: `construct://add-contact?id=...&username=...`

**Test with:**
1. Use Test Scan button to verify flow works
2. Try scanning other QR codes to test camera
3. Check console for QR detection logs

## Testing Workflow

### On Simulator
```
1. Open QR Scanner
2. See "Simulate QR Scan" button automatically
3. Tap to test contact addition flow
4. OR: Open Debug Panel → Test Scan
```

### On Real Device
```
1. Grant camera permission when prompted
2. If black screen:
   a. Open Debug Panel (ℹ️)
   b. Check all status indicators
   c. Review console logs
   d. Use Test Scan if camera fails
3. Scan real QR code
4. Verify contact added
```

## Manual Test Mode on Real Device

To enable test mode on a real device for development:

**Edit QRScannerView.swift:**
```swift
private var testMode: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return true  // ← Change from false to true
    #endif
}
```

**Result:**
- Shows "Simulate QR Scan" button even with working camera
- Useful for testing without generating QR codes
- Can compare test vs real scan behavior

## Console Log Guide

### Initialization Sequence (Success)
```
✅ Camera permission granted          // Permission OK
✅ Camera session ready                // Session configured
✅ Camera session started              // Camera running
📱 makeUIView called                   // UI created
🔄 updateUIView called                 // UI updating
   isSessionReady: true                // Session ready
   hasLayer: false                     // Layer not added yet
✅ Adding preview layer to view        // Layer added ✓
```

### Common Errors

**Permission Denied:**
```
❌ Camera permission denied
```
Fix: Settings → Privacy → Camera

**No Camera Device:**
```
❌ No video capture device available
```
Likely simulator or broken camera hardware

**Session Setup Failed:**
```
❌ Cannot add video input
❌ Cannot add metadata output
```
Check for other apps using camera, or restart device

**Preview Layer Failed:**
```
❌ getPreviewLayer returned nil
```
Race condition - session not ready when layer requested

## Performance Monitoring

Watch for these in console:
- Multiple `updateUIView` calls = normal
- `Adding preview layer` appearing multiple times = BUG (should be once)
- `Session Ready` flipping true/false = BUG

## Integration Testing

**Test complete flow:**
1. Enable test mode
2. Tap "Test Scan"
3. Verify contact added to NewChatView
4. Verify User entity created in Core Data
5. Verify Chat can be opened
6. Send test message

## Troubleshooting Checklist

- [ ] Camera permission granted (Settings)
- [ ] NSCameraUsageDescription in Info.plist
- [ ] App running on real device (not simulator)
- [ ] No other app using camera
- [ ] iOS version supports AVFoundation (iOS 10+)
- [ ] Device has working camera
- [ ] Good lighting conditions
- [ ] QR code format correct
- [ ] Debug panel shows all ✅ green

## Known Limitations

1. **Simulator**: No real camera, only test mode works
2. **iPad**: May require landscape orientation
3. **Portrait only**: App locked to portrait, camera matches
4. **iOS < 13**: Not tested, may have issues

## Support

If camera still doesn't work after following this guide:
1. Share console logs (including errors)
2. Share debug panel screenshot
3. Specify device model and iOS version
4. Note when issue started (after update, etc.)
