cask "minuteur-atelier" do
  version "1.0.2"
  sha256 "d264e1bc2f79ddd51b22f4a650221f26158960efa934eaa86f6f818ef9e67932"

  url "https://github.com/entropik/minuteur-atelier/releases/download/v#{version}/Minuteur-Atelier-v#{version}-macOS-universal.zip"
  name "Minuteur Atelier"
  desc "Panneau flottant macOS : Minuteur, Chrono et Tomate (Pomodoro strict) avec relevés CSV"
  homepage "https://github.com/entropik/minuteur-atelier"

  depends_on macos: ">= :sonoma"

  app "Minuteur-Atelier/Minuteur Atelier.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/Minuteur Atelier.app"]
  end

  zap trash: [
    "~/Library/Application Support/MinuteurAtelier",
    "~/Library/Preferences/com.ooblik.minuteur-atelier.plist",
  ]
end
