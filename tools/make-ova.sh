#!/usr/bin/env bash
# Erzeugt eine OVA (OVF 1.0 + streamOptimized VMDK) aus einem Raw-Image.
# Importierbar in VirtualBox und VMware (Workstation, Player, Fusion, ESXi).
# Aufruf: make-ova.sh DISK.raw AUSGABE.ova
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config.sh
source "$ROOT/config.sh"

RAW="${1:?Raw-Image fehlt}"
OVA="${2:?Ausgabedatei fehlt}"
NAME="$(basename "$OVA" .ova)"
TMP="$(mktemp -d "$(dirname "$RAW")/ova.XXXX")"
trap 'rm -rf "$TMP"' EXIT

CPUS="${VM_CPUS:-2}"
RAM_MB="${VM_RAM_MB:-4096}"

VMDK="$NAME-disk1.vmdk"
qemu-img convert -p -O vmdk -o subformat=streamOptimized,adapter_type=lsilogic \
    "$RAW" "$TMP/$VMDK"
CAPACITY="$(stat -c %s "$RAW")"
FILESIZE="$(stat -c %s "$TMP/$VMDK")"

cat > "$TMP/$NAME.ovf" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope ovf:version="1.0" xml:lang="de-DE"
    xmlns="http://schemas.dmtf.org/ovf/envelope/1"
    xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
    xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
    xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
    xmlns:vmw="http://www.vmware.com/schema/ovf"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <References>
    <File ovf:id="file1" ovf:href="$VMDK" ovf:size="$FILESIZE"/>
  </References>
  <DiskSection>
    <Info>Virtuelle Festplatten</Info>
    <Disk ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:capacity="$CAPACITY"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <NetworkSection>
    <Info>Netzwerke</Info>
    <Network ovf:name="NAT"><Description>NAT-Netzwerk</Description></Network>
  </NetworkSection>
  <VirtualSystem ovf:id="$NAME">
    <Info>${DISTRO_NAME} ${DISTRO_VERSION}</Info>
    <Name>${DISTRO_NAME} ${DISTRO_VERSION}</Name>
    <ProductSection>
      <Info>Produktinformationen</Info>
      <Product>${DISTRO_NAME}</Product>
      <Version>${DISTRO_VERSION}</Version>
      <ProductUrl>${HOME_URL}</ProductUrl>
    </ProductSection>
    <OperatingSystemSection ovf:id="94" vmw:osType="ubuntu64Guest">
      <Info>Gastbetriebssystem</Info>
      <Description>Ubuntu (64-bit)</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtuelle Hardware</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>$NAME</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-14 virtualbox-2.2</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Anzahl virtueller CPUs</rasd:Description>
        <rasd:ElementName>$CPUS CPU</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>$CPUS</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Arbeitsspeicher</rasd:Description>
        <rasd:ElementName>$RAM_MB MB RAM</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>$RAM_MB</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>SCSI-Controller</rasd:Description>
        <rasd:ElementName>SCSI-Controller 0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>lsilogic</rasd:ResourceSubType>
        <rasd:ResourceType>6</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>Festplatte 1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>NAT</rasd:Connection>
        <rasd:ElementName>Netzwerkkarte 1</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>E1000</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
      <Item ovf:required="false">
        <rasd:AutomaticAllocation>false</rasd:AutomaticAllocation>
        <rasd:ElementName>USB-Controller</rasd:ElementName>
        <rasd:InstanceID>6</rasd:InstanceID>
        <rasd:ResourceType>23</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
EOF

(
    cd "$TMP"
    {
        echo "SHA256($NAME.ovf)= $(sha256sum "$NAME.ovf" | cut -d' ' -f1)"
        echo "SHA256($VMDK)= $(sha256sum "$VMDK" | cut -d' ' -f1)"
    } > "$NAME.mf"
    # Die OVF-Datei muss als erstes im Archiv stehen
    tar --format=ustar -cf "$OVA" "$NAME.ovf" "$VMDK" "$NAME.mf"
)
echo "$OVA"
