// Helper for tools/screenshots.sh.
//
//   grab --window-id        print the Notification Center window id
//   grab --crop in out      crop a PNG to its non-transparent content
//
// macOS draws notifications inside one full-screen, mostly transparent
// Notification Center window, so there is no per-banner window to capture.
// screencapture(1) grabs that window; this crops the result down to the
// banner actually drawn in it.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

static int PrintWindowID(void) {
  NSArray *windows = (__bridge_transfer NSArray *)CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  for (NSDictionary *w in windows) {
    if ([w[(id)kCGWindowOwnerName] isEqualToString:@"Notification Center"]) {
      printf("%u\n", [w[(id)kCGWindowNumber] unsignedIntValue]);
      return 0;
    }
  }
  fprintf(stderr, "grab: no Notification Center window on screen\n");
  return 1;
}

static CGRect ContentBounds(CGImageRef image) {
  size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
  if (w == 0 || h == 0) return CGRectNull;

  size_t bytesPerRow = w * 4;
  uint8_t *data = calloc(h, bytesPerRow);
  if (!data) return CGRectNull;

  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(
      data, w, h, 8, bytesPerRow, space,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (!ctx) { free(data); return CGRectNull; }
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
  CGContextRelease(ctx);

  size_t minX = w, minY = h, maxX = 0, maxY = 0;
  BOOL found = NO;
  for (size_t y = 0; y < h; y++) {
    for (size_t x = 0; x < w; x++) {
      // The overlay is not perfectly clear, so ignore near-transparent pixels.
      if (data[y * bytesPerRow + x * 4 + 3] > 8) {
        found = YES;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  free(data);
  if (!found) return CGRectNull;
  return CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);
}

static int Crop(const char *inPath, const char *outPath) {
  NSURL *inURL = [NSURL fileURLWithPath:@(inPath)];
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)inURL, NULL);
  if (!src) { fprintf(stderr, "grab: cannot read %s\n", inPath); return 1; }
  CGImageRef image = CGImageSourceCreateImageAtIndex(src, 0, NULL);
  CFRelease(src);
  if (!image) { fprintf(stderr, "grab: cannot decode %s\n", inPath); return 1; }

  CGRect box = ContentBounds(image);
  if (CGRectIsNull(box) || box.size.width < 40 || box.size.height < 20) {
    CGImageRelease(image);
    fprintf(stderr, "grab: no notification visible in the capture\n");
    return 1;
  }

  const CGFloat pad = 16;
  CGRect padded = CGRectIntersection(
      CGRectInset(box, -pad, -pad),
      CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image)));

  CGImageRef cropped = CGImageCreateWithImageInRect(image, padded);
  CGImageRelease(image);
  if (!cropped) { fprintf(stderr, "grab: crop failed\n"); return 1; }

  NSURL *outURL = [NSURL fileURLWithPath:@(outPath)];
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)outURL, (CFStringRef)@"public.png", 1, NULL);
  if (!dest) { CGImageRelease(cropped); fprintf(stderr, "grab: cannot write %s\n", outPath); return 1; }
  CGImageDestinationAddImage(dest, cropped, NULL);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  printf("  %s  %zux%zu\n", outPath, CGImageGetWidth(cropped), CGImageGetHeight(cropped));
  CGImageRelease(cropped);
  return ok ? 0 : 1;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc >= 2 && strcmp(argv[1], "--window-id") == 0) return PrintWindowID();
    if (argc >= 4 && strcmp(argv[1], "--crop") == 0) return Crop(argv[2], argv[3]);
    fprintf(stderr, "usage: grab --window-id | grab --crop <in.png> <out.png>\n");
    return 2;
  }
}
