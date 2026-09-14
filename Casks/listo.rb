cask "listo" do
  version "0.1.0"
  sha256 :no_check # replace with `shasum -a 256 dist/Listo-<version>.zip` on first real release

  url "https://github.com/yourname/listo/releases/download/v#{version}/Listo-#{version}.zip"
  name "Listo"
  desc "Lista de tareas que vive como Markdown plano en tu disco"
  homepage "https://github.com/yourname/listo"

  depends_on macos: ">= :sonoma"

  app "Listo.app"

  zap trash: [
    "~/Library/Preferences/com.listo.app.plist",
    "~/Library/Saved Application State/com.listo.app.savedState",
  ]
end
