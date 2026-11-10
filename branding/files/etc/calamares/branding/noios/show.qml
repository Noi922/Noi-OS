/* Noi OS – Diashow während der Installation (Calamares slideshowAPI 1) */
import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation {
    id: presentation

    Timer {
        interval: 9000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    component NoiSlide: Slide {
        property string title
        property string body
        Image {
            anchors.fill: parent
            source: "slide-bg.png"
            fillMode: Image.PreserveAspectCrop
        }
        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.78
            height: col.height + 60
            radius: 14
            color: "#d91c2118"
            border.color: "#6b8a30"
            border.width: 2
            Column {
                id: col
                anchors.centerIn: parent
                width: parent.width - 60
                spacing: 16
                Text {
                    width: parent.width
                    text: title
                    color: "#c9d3a0"
                    font.pixelSize: 30
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }
                Text {
                    width: parent.width
                    text: body
                    color: "#e2e6d4"
                    font.pixelSize: 17
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }
            }
        }
    }

    NoiSlide {
        title: "Willkommen bei Noi OS"
        body: "Ein schneller, aufgeräumter KDE-Plasma-Desktop auf dem soliden Fundament von Ubuntu 24.04 LTS – in Camouflage-Grün."
    }
    NoiSlide {
        title: "Alles dabei"
        body: "Firefox, LibreOffice, VLC, Dolphin, Kate und mehr sind bereits installiert. Weitere Programme findest du in Discover."
    }
    NoiSlide {
        title: "Ohne Snap, mit Flatpak"
        body: "Noi OS setzt auf klassische .deb-Pakete und Flatpak. Firefox kommt direkt von Mozilla."
    }
    NoiSlide {
        title: "Langzeit-Support"
        body: "Sicherheitsupdates von Ubuntu bis 2029 – einfach über die Aktualisierungsverwaltung."
    }
}
