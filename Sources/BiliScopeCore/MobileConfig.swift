import Foundation

/// Builds the `.mobileconfig` payload that installs the root CA on iOS.
public enum MobileConfig {
    public static func make(rootDER: Data, displayName: String) -> String {
        let uuid = UUID().uuidString
        let base64 = rootDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <array>
                <dict>
                    <key>PayloadCertificateFileName</key>
                    <string>bili-scope-ca.cer</string>
                    <key>PayloadContent</key>
                    <data>
        \(base64)
                    </data>
                    <key>PayloadDescription</key>
                    <string>BiliScope 根证书，仅用于解密 B 站视频 CDN 流量。</string>
                    <key>PayloadDisplayName</key>
                    <string>\(displayName)</string>
                    <key>PayloadIdentifier</key>
                    <string>com.biliscope.root.\(uuid)</string>
                    <key>PayloadType</key>
                    <string>com.apple.security.root</string>
                    <key>PayloadUUID</key>
                    <string>\(uuid)</string>
                    <key>PayloadVersion</key>
                    <integer>1</integer>
                </dict>
            </array>
            <key>PayloadDisplayName</key>
            <string>\(displayName)</string>
            <key>PayloadIdentifier</key>
            <string>com.biliscope.profile.\(uuid)</string>
            <key>PayloadOrganization</key>
            <string>BiliScope</string>
            <key>PayloadRemovalDisallowed</key>
            <false/>
            <key>PayloadType</key>
            <string>Configuration</string>
            <key>PayloadUUID</key>
            <string>\(uuid)</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        </plist>
        """
    }
}
