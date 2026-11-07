cask "zefra" do
  version "0.1.0"
  sha256 "851da23b3a387de87d7df5a94c057d487b0602d9410a33ca30438d913455e2bf"

  url "https://github.com/Naqara-Dev/Zefra/releases/download/v#{version}/Zefra-#{version}.dmg"
  name "Zefra"
  desc "Temperatures, fan control and hardware diagnostics"
  homepage "https://github.com/Naqara-Dev/Zefra"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Zefra.app"
  binary "#{appdir}/Zefra.app/Contents/MacOS/Zefra", target: "zefra"

  uninstall launchctl: "com.naqara.zefra.helper",
            delete:    [
              "/Library/LaunchDaemons/com.naqara.zefra.helper.plist",
              "/Library/PrivilegedHelperTools/com.naqara.zefra.helper",
            ]

  zap trash: [
    "~/Library/Application Support/Zefra",
    "~/Library/Preferences/com.naqara.zefra.plist",
  ]
end
