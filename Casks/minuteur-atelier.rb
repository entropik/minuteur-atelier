cask "minuteur-atelier" do
  version "1.0.3"
  sha256 "fc881d1b0710dc70956cc1844b1d6292a439f682006037ae9c0c706cdbbef36a"

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
