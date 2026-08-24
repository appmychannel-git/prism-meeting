# iOS 브랜드별 Firebase 설정 (GoogleService-Info.plist)

브랜드마다 Firebase iOS 앱이 다르므로, 각 브랜드의 `GoogleService-Info.plist` 를
아래 위치에 둔다. `scripts/build_ios_brand.sh <brand>` 가 빌드 시 이 파일을
`ios/Runner/GoogleService-Info.plist` 로 복사한다.

```
ios/firebase/gbled/GoogleService-Info.plist
ios/firebase/viewplus/GoogleService-Info.plist
ios/firebase/mychannel/GoogleService-Info.plist
ios/firebase/ecoglow/GoogleService-Info.plist
```

(prism 은 예외: `ios/Runner/GoogleService-Info.plist` 가 저장소 원본이므로 여기 둘 필요 없음.)

## 받는 법
Firebase 콘솔 → 프로젝트 `mychannel-meeting-ed929` → 앱 추가(iOS) → 번들 ID 입력 → plist 다운로드.

| 브랜드 | Bundle ID |
|--------|-----------|
| gbled | kr.co.mychannel.meeting.gbled |
| viewplus | kr.co.mychannel.meeting.viewplus |
| mychannel | kr.co.mychannel.meeting |
| ecoglow | kr.co.mychannel.meeting.ecoglowkc |

> 이 plist 들은 앱 식별정보라 커밋해도 치명적이진 않으나, 커밋하지 않으려면
> `.gitignore` 에 `ios/firebase/*/GoogleService-Info.plist` 를 추가하고 Mac 에만 둔다.
