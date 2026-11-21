# whisper.cpp source provenance

Upstream: https://github.com/ggml-org/whisper.cpp
Release: v1.9.5, commit d1be6fde11ac6e0407606b4e42fe72d34add8037.
Vendored CMakeLists.txt, cmake, include, src and ggml, with MIT LICENSE.
Upstream sources are unmodified. Application JNI is in android/app/src/main/cpp.
CPU only; no OpenMP, GPU, runtime fetches or Python dependency on Android.
