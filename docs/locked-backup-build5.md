# Locked-phone backup follow-up (build 5)

- Guard background ownership so a delayed temporary UIKit expiration cannot cancel a continued-processing task.
- Report measured iCloud retrieval and upload/read-back progress across resources, including Live Photos.
- Distinguish temporary background expiration from continued-processing expiration/system Stop.
- Normal fast resume remains destination-scoped and durable; completed-item verification is still explicitly requested.

Validation: 80 signed simulator tests passed, including expiration ordering, late callbacks, journal persistence and data verification. Real locked-device duration still requires testing; the reported incident cannot be attributed conclusively without device logs. iOS may end continued processing under resource constraints or system Stop. No automatic restart overrides Stop.

Phone check: start backup, wait for background-enabled status, lock for several minutes, then confirm completed count increased. Also verify another-tab navigation and Stop/fast resume. Include a large video and Live Photo.
