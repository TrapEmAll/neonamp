const int minimumLibraryCacheMegabytes = 64;
const int maximumLibraryCacheMegabytes = 2048;

int libraryCacheBytesFromMegabytes(int megabytes) =>
    megabytes * 1024 * 1024;
