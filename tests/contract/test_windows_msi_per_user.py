"""Guardrail tests ensuring Windows MSI packaging stays strictly per-user."""
from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
WIX4_TEMPLATE = ROOT / "packaging/windows/Product.template.wxs"
WIX3_TEMPLATE = ROOT / "packaging/windows/Product.wix3.template.wxs"
PACKAGE_SCRIPT = ROOT / "scripts/package-windows.ps1"


def _parse_template(path: Path) -> ET.Element:
    rendered = (
        path.read_text(encoding="utf-8")
        .replace("{{VERSION}}", "2.4.0")
        .replace("{{DIRECTORY_TREE}}", "")
        .replace("{{COMPONENTS}}", "")
    )
    return ET.fromstring(rendered)


def test_wix4_template_is_strictly_per_user():
    text = WIX4_TEMPLATE.read_text(encoding="utf-8")
    assert "perMachine" not in text
    assert "ProgramFiles64Folder" not in text
    assert "ProgramFilesFolder" not in text
    assert "ALLUSERS" not in text

    root = _parse_template(WIX4_TEMPLATE)
    ns = {"w": "http://wixtoolset.org/schemas/v4/wxs"}
    package = root.find("w:Package", ns)
    assert package is not None
    assert package.attrib.get("Scope") == "perUser"
    assert root.find(".//w:StandardDirectory[@Id='LocalAppDataFolder']", ns) is not None
    assert root.find(".//w:Directory[@Id='ProgramsDir'][@Name='Programs']/w:Directory[@Id='INSTALLFOLDER']", ns) is not None


def test_wix3_template_is_strictly_per_user():
    text = WIX3_TEMPLATE.read_text(encoding="utf-8")
    assert "perMachine" not in text
    assert "ProgramFiles64Folder" not in text
    assert "ProgramFilesFolder" not in text
    assert "ALLUSERS" not in text

    root = _parse_template(WIX3_TEMPLATE)
    ns = {"w": "http://schemas.microsoft.com/wix/2006/wi"}
    package = root.find(".//w:Package", ns)
    assert package is not None
    assert package.attrib.get("InstallScope") == "perUser"
    assert package.attrib.get("InstallPrivileges") == "limited"
    assert root.find(".//w:Directory[@Id='LocalAppDataFolder']", ns) is not None
    assert root.find(".//w:Directory[@Id='ProgramsDir'][@Name='Programs']/w:Directory[@Id='INSTALLFOLDER']", ns) is not None


def test_package_windows_script_uses_hkcu_keypaths_and_folder_cleanup():
    script = PACKAGE_SCRIPT.read_text(encoding="utf-8")
    assert 'Root=""HKCU""' in script
    assert 'KeyPath=""yes""' in script
    assert '<File Id=""$FileId"" Name=""$Name"" Source=""$Source"" />' in script
    assert 'KeyPath=""yes"" />' not in script.split('<File ')[1].split('\n')[0]
    assert 'RemoveFolder' in script
    assert 'RMV_INSTALLFOLDER' in script
    assert 'New-DeterministicGuid' in script
    assert 'Guid=""$ComponentGuid""' in script
