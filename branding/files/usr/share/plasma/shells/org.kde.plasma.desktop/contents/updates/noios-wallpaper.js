// Noi OS: Camouflage-Hintergrundbild für alle Desktops setzen (läuft einmal pro Nutzer)
var wallpaper = "/usr/share/wallpapers/NoiCamo/";
desktops().forEach(function (d) {
    d.wallpaperPlugin = "org.kde.image";
    d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    d.writeConfig("Image", wallpaper);
});
