cask "minuteur-atelier" do
  version "1.0.0"
  sha256 "0fae61dd330d7d9cecbd54633aa6adb4cd102716a5954ee7bf97d182b01ee30f"

  url "https://github.com/entropik/minuteur-atelier/releases/download/v#{version}/Minuteur-Atelier-v#{version}-macOS-universal.zip"
  name "Minuteur Atelier"
  desc "Panneau flottant macOS : Minuteur, Chrono et Tomate (Pomodoro strict) avec relevés CSV"
  homepage "https://github.com/entropik/minuteur-atelier"

  depends_on macos: ">= :sonoma"

  app "Minuteur-Atelier-Dist/Minuteur Atelier.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/Minuteur Atelier.app"]
  end

  zap trash: [
    "~/Library/Application Support/MinuteurAtelier",
    "~/Library/Preferences/com.ooblik.minuteur-atelier.plist",
  ]
end
