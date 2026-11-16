# Local CameraX 0.7.6 changes

Upstream BSD license retained. Runtime dependencies unchanged.

- NV21 API accepts ImageProxy directly, skipping getPlanes/Pigeon plane buffer
  serialization. Return the newly packed byte array without copying it again.
- Tight output allocation (width*height*3/2) for padded Y rows. Duplicate source
  ByteBuffers to preserve their positions; no output byte arrays reused while
  codec delivery is in flight.
- Optional frameAdmission callback runs before fetching any plane bytes. Dropped
  proxies are closed immediately; accepted proxies close in finally on errors.
- Optional frameProfile callback measures conversion/channel duration and bytes.
- Optional analysis dimensions apply to ImageAnalysis only; Preview/ImageCapture
  retain the controller preset. Defaults preserve the upstream resolution.
- Pigeon schema and both generated bindings changed together. Regeneration with
  upstream Pigeon 27.3.2 must preserve the ImageProxy argument.

The application supplies admission/profiling callbacks only for its page lifetime.
Do not edit global Pub cache copies: pubspec overrides this local package.
