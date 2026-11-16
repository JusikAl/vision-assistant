"""Test the production Java NV21 packer, no Gradle/network dependencies.
Minimal compile-time Android interfaces replace only framework types.
Usage: python tool/check_nv21_packing.py --java-home <JDK directory>
"""
from pathlib import Path
import argparse, os, subprocess, shutil
parser = argparse.ArgumentParser()
parser.add_argument('--java-home', default=os.environ.get('JAVA_HOME'))
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
build = root / 'build/yolo_diagnostics/v4/java_packing'
build.mkdir(parents=True, exist_ok=True)
files = {
 'androidx/annotation/NonNull.java': 'package androidx.annotation; public @interface NonNull {}',
 'androidx/camera/core/ImageProxy.java': 'package androidx.camera.core; public interface ImageProxy { interface PlaneProxy { java.nio.ByteBuffer getBuffer(); int getRowStride(); int getPixelStride(); } }'
}
for name, content in files.items():
 path = build / name
 path.parent.mkdir(parents=True, exist_ok=True)
 path.write_text(content)
def executable(name):
 if args.java_home:
  return str(Path(args.java_home) / 'bin' / (name + ('.exe' if os.name == 'nt' else '')))
 found = shutil.which(name)
 if not found: raise SystemExit('JDK required: provide --java-home')
 return found
sources = [str(build / name) for name in files]
sources += [str(root / 'third_party/camera_android_camerax/android/src/main/java/io/flutter/plugins/camerax/ImageProxyUtils.java'), str(root / 'tool/NativeNv21PackingCheck.java')]
subprocess.run([executable('javac'), '-d', str(build / 'classes'), *sources], check=True)
subprocess.run([executable('java'), '-cp', str(build / 'classes'), 'NativeNv21PackingCheck'], check=True)
