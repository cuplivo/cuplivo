/// Official Ubuntu base rootfs tarball URLs for Android PRoot sandboxes.
class AndroidRootfsUrls {
  AndroidRootfsUrls._();

  static const String arm64 =
      'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/'
      'ubuntu-base-24.04.3-base-arm64.tar.gz';

  static const String amd64 =
      'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/'
      'ubuntu-base-24.04.3-base-amd64.tar.gz';

  /// Maps channel ABI (`arm64-v8a` / `x86_64`) to download URL.
  static String? urlForAbi(String abi) {
    switch (abi) {
      case 'arm64-v8a':
        return arm64;
      case 'x86_64':
        return amd64;
      default:
        return null;
    }
  }
}
