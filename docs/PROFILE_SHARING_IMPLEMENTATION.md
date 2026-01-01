# Profile Sharing Implementation Plan

## Overview
Privacy-first peer-to-peer profile sharing without server storage.
Display names and avatars are shared directly between contacts through encrypted messages.

## Current State

### Swift (Core Data)
```swift
// User entity - ✅ Already has fields
@NSManaged public var displayName: String
@NSManaged public var avatarData: Data?
```

### Rust (Core)
```rust
// StoredContact - ❌ Missing fields
pub struct StoredContact {
    pub id: String,
    pub username: String,
    // Missing: display_name, avatar_data, avatar_version
    pub public_key_bundle: Option<Vec<u8>>,
    pub added_at: i64,
    pub last_message_at: Option<i64>,
}

// AppState - ❌ Missing current user profile
pub struct AppState<P: CryptoProvider> {
    user_id: Option<String>,
    username: Option<String>,
    // Missing: display_name, avatar_data
}
```

## Implementation Plan

### Phase 1: Contact Link Enhancement

#### 1.1 Update QR Code/Contact Link Format

**Current:**
```
construct://add-contact?id=UUID&username=alice
```

**New:**
```
construct://add-contact?id=UUID&username=alice&display_name=Alice%20Smith&avatar_version=1
```

**Files to modify:**
- `ConstructMessenger/Views/Settings/ContactQRCodeView.swift` (line 17)
- `ConstructMessenger/Views/Settings/AccountSettingsView.swift` (line 182)

#### 1.2 Update Contact Link Parsing

**File:** `ConstructMessenger/Views/Chats/NewChatView.swift` (lines 86-117)

Add parsing for new parameters:
```swift
var displayName: String?
var avatarVersion: Int?

for item in queryItems {
    if item.name == "id" {
        userId = item.value
    } else if item.name == "username" {
        username = item.value
    } else if item.name == "display_name" {
        displayName = item.value?.removingPercentEncoding
    } else if item.name == "avatar_version" {
        avatarVersion = Int(item.value ?? "0")
    }
}
```

### Phase 2: Profile Exchange Protocol

#### 2.1 Define Profile Data Structures

**File:** `packages/core/src/protocol/messages.rs`

Add new structures:
```rust
/// Profile information shared between contacts
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileData {
    pub display_name: String,
    /// Base64 JPEG compressed avatar (max 50KB)
    pub avatar: Option<String>,
    /// Version number for avatar updates
    pub avatar_version: u32,
}

/// Message payload types (inside encrypted ChatMessage content)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum MessagePayload {
    /// Regular text message
    Text { text: String },

    /// Session initialization with profile
    SessionInit {
        profile: ProfileData,
        text: Option<String>,
    },

    /// Profile update notification
    ProfileUpdate {
        profile: ProfileData,
    },
}
```

#### 2.2 Update Storage Models

**File:** `packages/core/src/storage/models.rs`

```rust
/// Контакт в хранилище
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredContact {
    pub id: String,
    pub username: String,
    pub display_name: Option<String>,        // NEW
    pub avatar_data: Option<Vec<u8>>,        // NEW - compressed JPEG
    pub avatar_version: u32,                 // NEW - for sync
    pub public_key_bundle: Option<Vec<u8>>,
    pub added_at: i64,
    pub last_message_at: Option<i64>,
}
```

#### 2.3 Update AppState

**File:** `packages/core/src/state/app.rs`

```rust
pub struct AppState<P: CryptoProvider> {
    user_id: Option<String>,
    username: Option<String>,
    display_name: Option<String>,            // NEW
    avatar_data: Option<Vec<u8>>,            // NEW
    avatar_version: u32,                     // NEW
    // ... rest of fields
}

impl<P: CryptoProvider> AppState<P> {
    /// Set current user's profile
    pub fn set_profile(&mut self, display_name: String, avatar: Option<Vec<u8>>) {
        self.display_name = Some(display_name);
        if avatar.is_some() {
            self.avatar_version += 1;
        }
        self.avatar_data = avatar;
    }

    /// Get current user's profile
    pub fn get_profile(&self) -> ProfileData {
        ProfileData {
            display_name: self.display_name.clone()
                .unwrap_or_else(|| self.username.clone().unwrap_or_default()),
            avatar: self.avatar_data.as_ref()
                .map(|data| base64::encode(data)),
            avatar_version: self.avatar_version,
        }
    }
}
```

### Phase 3: Message Flow

#### 3.1 Initial Profile Exchange

**When:** After scanning QR and establishing Double Ratchet session

**Flow:**
1. User A scans User B's QR code
2. QR contains: `id`, `username`, `display_name`, `avatar_version`
3. User A initiates session with User B
4. First message includes `SessionInit` payload:
   ```json
   {
     "type": "sessionInit",
     "profile": {
       "display_name": "Alice Smith",
       "avatar": "base64_jpeg_data",
       "avatar_version": 1
     },
     "text": "Hi! 👋"
   }
   ```
5. User B receives encrypted message, decrypts, saves profile to Core Data

#### 3.2 Profile Updates

**When:** User changes display name or avatar in settings

**Flow:**
1. User updates profile in AccountSettingsView
2. Swift saves to Core Data (already working)
3. Swift calls Rust: `updateProfile(displayName, avatarData)`
4. Rust increments `avatar_version` if avatar changed
5. Rust sends `ProfileUpdate` to ALL contacts:
   ```json
   {
     "type": "profileUpdate",
     "profile": {
       "display_name": "New Name",
       "avatar": "base64_jpeg_data",
       "avatar_version": 2
     }
   }
   ```
6. Each contact receives update, saves to their local Core Data

### Phase 4: Swift Integration

#### 4.1 Update SettingsViewModel

**File:** `ConstructMessenger/ViewModels/SettingsViewModel.swift`

```swift
func saveDisplayName(_ name: String) {
    guard let context = viewContext, !userId.isEmpty else { return }

    let trimmed = name.trimmingCharacters(in: .whitespaces)

    // Save to Core Data (existing code)
    // ...

    // NEW: Notify Rust and broadcast to contacts
    RustMessenger.shared.updateProfile(
        displayName: trimmed,
        avatar: profileImage
    )
}

func saveAvatar(_ image: UIImage) {
    guard let context = viewContext, !userId.isEmpty else { return }

    guard let processedData = ImageHelper.prepareAvatarImage(image) else {
        return
    }

    // Save to Core Data (existing code)
    // ...

    // NEW: Notify Rust and broadcast to contacts
    RustMessenger.shared.updateProfile(
        displayName: displayName,
        avatar: image
    )
}
```

#### 4.2 Handle Incoming Profile Updates

**New file:** `ConstructMessenger/Services/ProfileUpdateHandler.swift`

```swift
class ProfileUpdateHandler {
    static func handleProfileUpdate(
        fromUserId: String,
        profile: ProfileData,
        context: NSManagedObjectContext
    ) {
        // Find user in Core Data
        let fetchRequest: NSFetchRequest<User> = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", fromUserId)

        guard let user = try? context.fetch(fetchRequest).first else {
            return
        }

        // Update display name
        user.displayName = profile.displayName

        // Update avatar if version is newer
        if let avatarBase64 = profile.avatar,
           let avatarData = Data(base64Encoded: avatarBase64) {
            user.avatarData = avatarData
        }

        try? context.save()

        // Notify UI to refresh
        NotificationCenter.default.post(
            name: .profileDidUpdate,
            object: fromUserId
        )
    }
}
```

### Phase 5: Privacy Considerations

#### 5.1 Avatar Size Limits
- Max size: 50KB compressed JPEG
- Recommended: 200x200px @ 70% quality
- Already implemented in `ImageHelper.prepareAvatarImage()`

#### 5.2 Profile Update Rate Limiting
- Don't spam contacts with updates
- Batch updates if multiple changes within 5 seconds
- Store pending updates, send as single message

#### 5.3 Selective Sharing (Future Enhancement)
Allow users to choose which contacts see their profile:
```swift
struct ProfileVisibility {
    let displayName: Bool
    let avatar: Bool
    let status: Bool
}

// Per-contact settings
contactSettings[contactId] = ProfileVisibility(
    displayName: true,
    avatar: false,  // Hide avatar from this contact
    status: true
)
```

## Implementation Order

1. ✅ **Document created** (this file)
2. ⏳ Update Rust storage models (`StoredContact`, `AppState`)
3. ⏳ Add `ProfileData` and `MessagePayload` to protocol
4. ⏳ Implement profile exchange in first message
5. ⏳ Add profile update broadcasting
6. ⏳ Update Swift ViewModels to call Rust
7. ⏳ Add incoming profile update handler
8. ⏳ Update QR code generation with profile data
9. ⏳ Update contact link parsing
10. ⏳ Test end-to-end profile sharing

## Testing Checklist

- [ ] QR code includes display name and avatar version
- [ ] Contact link parses display name correctly
- [ ] First message includes sender's profile
- [ ] Profile saved to recipient's Core Data
- [ ] Display name change broadcasts to all contacts
- [ ] Avatar change increments version number
- [ ] Avatar change broadcasts to all contacts
- [ ] Contacts receive and display updated profiles
- [ ] Works offline (queued updates sent when online)
- [ ] Avatar size limits enforced
- [ ] No PII sent to server (all E2E encrypted)

## Security Notes

- All profile data transmitted through encrypted ChatMessage
- Server only sees encrypted blob, never display names or avatars
- Profile updates are authenticated (sender verified via Double Ratchet)
- No replay attacks possible (message numbers prevent replay)
- Avatar data validated before display (image format, size limits)

## Future Enhancements

1. **Profile History**: Keep history of profile changes per contact
2. **Verification Badges**: Mark verified contacts differently
3. **Status Messages**: "Available", "Busy", etc. (also E2E encrypted)
4. **Profile Expiry**: Automatically request fresh profile after N days
5. **Granular Permissions**: Per-contact profile visibility settings
