"""Fetch the license-cleared default GM SoundFont used by NeonAmp builds."""

from hashlib import sha256
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.request import Request, urlopen


URL = (
    "https://ftp.jaist.ac.jp/pub/sourceforge.jp/sfnet/a/an/"
    "androidframe/soundfonts/FluidR3_GM.sf2"
)
EXPECTED_SIZE = 148_398_306
EXPECTED_SHA256 = "74594e8f4250680adf590507a306655a299935343583256f3b722c48a1bc1cb0"
TARGET = Path(__file__).resolve().parents[1] / "assets" / "soundfonts" / "FluidR3_GM.sf2"


def fingerprint(path: Path) -> tuple[int, str]:
    digest = sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return path.stat().st_size, digest.hexdigest()


def main() -> None:
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    if TARGET.exists() and fingerprint(TARGET) == (EXPECTED_SIZE, EXPECTED_SHA256):
        print(f"Default SoundFont already verified: {TARGET}")
        return

    request = Request(URL, headers={"User-Agent": "NeonAmp build asset fetcher"})
    with urlopen(request, timeout=120) as response, NamedTemporaryFile(
        mode="wb", dir=TARGET.parent, delete=False
    ) as temporary:
        temporary_path = Path(temporary.name)
        while chunk := response.read(1024 * 1024):
            temporary.write(chunk)

    try:
        actual = fingerprint(temporary_path)
        if actual != (EXPECTED_SIZE, EXPECTED_SHA256):
            raise RuntimeError(
                f"Unexpected SoundFont fingerprint: size={actual[0]}, sha256={actual[1]}"
            )
        temporary_path.replace(TARGET)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()
    print(f"Fetched verified default SoundFont: {TARGET}")


if __name__ == "__main__":
    main()

