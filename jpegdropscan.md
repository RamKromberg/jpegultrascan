# jpegdropscan
JPEG lossy recompressor that removes least informative scans to reach a target quality

## Command line usage
    perl jpegdropscan.pl [switches] inputfile outputfile

## Switches
    -d N     Maximum quality metric difference level (default: 0)
    -r path  Path to reference image to use with quality metric evaluator (default: inputfile)
    -n [N]   Use quality (N = best, 100 default) rather than distance (0 = best)
    -q       Suppress all output
    -v       Verbose output
    -p path  Path to jpegtran (default: jpegtran)
    -c path  Path to quality metric evaluator (default: butteraugli)
    -b 0-13  Maximum number of bit splits to test (default: 3)

## Requirements
- [Perl](https://www.perl.org/)
- jpegtran from [libjpeg](https://jpegclub.org/reference/reference-sources/), [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo), or [mozjpeg](https://github.com/mozilla/mozjpeg)
- [butteraugli, SSIMULACRA 2](https://github.com/libjxl/libjxl) or other quality metric evaluator

## Notes
Rather than recoding an image, jpegdropscan iteratively removes scan information starting with least significant bits and moving to least significant coefficients. Originally developed using butteraugli for quality evaluation, but other metrics may be used.

Best results can be achieved by processing an image with [jpegultrascan](jpegultrascan.md) first, running jpegdropscan, then jpegultrascan once more.

## Author
Aaron Kaluszka <<megabyte@kontek.net>>
