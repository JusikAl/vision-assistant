// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import androidx.annotation.NonNull;

/**
 * ProxyApi implementation for {@link ImageProxyUtils}. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
public class ImageProxyUtilsProxyApi extends PigeonApiImageProxyUtils {
  private static final java.util.concurrent.atomic.AtomicLong packingCalls = new java.util.concurrent.atomic.AtomicLong();
  private static final java.util.concurrent.atomic.AtomicLong packingNanos = new java.util.concurrent.atomic.AtomicLong();

  /** On-demand profiling counters; no per-frame logging or image retention. */
  public static java.util.Map<String, Long> packingStats() {
    java.util.Map<String, Long> stats = new java.util.HashMap<>();
    stats.put("calls", packingCalls.get());
    stats.put("nanos", packingNanos.get());
    return stats;
  }

  ImageProxyUtilsProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public byte[] getNv21Buffer(@NonNull androidx.camera.core.ImageProxy image) {
    // Read planes natively: do not serialize all three plane buffers to Dart.
    final long started = System.nanoTime();
    final byte[] packed = ImageProxyUtils.planesToNV21(
        java.util.Arrays.asList(image.getPlanes()), image.getWidth(), image.getHeight()).array();
    packingNanos.addAndGet(System.nanoTime() - started);
    packingCalls.incrementAndGet();
    return packed;
  }
}
