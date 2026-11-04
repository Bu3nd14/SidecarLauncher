cask "sidecar-switch" do
  version "0.1.0"
  sha256 "a42f3c92869a88b21a5bb9b63ff543fa6e2e304c2d0797fce2c803835db23961"

  url "https://github.com/Bu3nd14/SidecarLauncher/releases/download/sidecar-switch-v#{version}/SidecarSwitch-#{version}.zip"
  name "SidecarSwitch"
  desc "Switch the iPad Sidecar session between two Macs"
  homepage "https://github.com/Bu3nd14/SidecarLauncher"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "SidecarSwitch.app"

  caveats <<~EOS
    SidecarSwitch non è notarizzata. Se macOS la blocca, usa "Apri comunque"
    in Impostazioni di Sistema → Privacy e Sicurezza, oppure:
      xattr -dr com.apple.quarantine "$HOME/Applications/SidecarSwitch.app"

    Configurazione:
      ~/Library/Application Support/SidecarSwitch/config.json

    Per installare in ~/Applications senza admin:
      brew install --cask --appdir="$HOME/Applications" bu3nd14/sidecarlauncher/sidecar-switch
  EOS

  zap trash: [
    "~/Library/Application Support/SidecarSwitch",
    "~/Library/Logs/SidecarSwitch",
    "~/.sidecar-switch",
  ]
end
