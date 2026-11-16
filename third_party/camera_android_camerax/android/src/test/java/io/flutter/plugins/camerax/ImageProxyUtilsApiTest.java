// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertArrayEquals;
import static org.mockito.Mockito.mockStatic;

import androidx.camera.core.ImageProxy.PlaneProxy;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.List;
import org.junit.Test;
import org.mockito.MockedStatic;
import org.mockito.Mockito;

public class ImageProxyUtilsApiTest {

  @Test
  public void getNv21Buffer_returnsExpectedBytes() {
    final PigeonApiImageProxyUtils api = new TestProxyApiRegistrar().getPigeonApiImageProxyUtils();

    List<PlaneProxy> planes =
        Arrays.asList(
            Mockito.mock(PlaneProxy.class),
            Mockito.mock(PlaneProxy.class),
            Mockito.mock(PlaneProxy.class));
    long width = 4;
    long height = 2;
    byte[] expectedBytes = new byte[] {1, 2, 3, 4, 5};
    ByteBuffer mockBuffer = ByteBuffer.wrap(expectedBytes);

    try (MockedStatic<ImageProxyUtils> mockedStatic = mockStatic(ImageProxyUtils.class)) {
      mockedStatic
          .when(
              () ->
                  ImageProxyUtils.planesToNV21(
                      Mockito.anyList(), Mockito.anyInt(), Mockito.anyInt()))
          .thenReturn(mockBuffer);

      androidx.camera.core.ImageProxy image = Mockito.mock(androidx.camera.core.ImageProxy.class);
      Mockito.when(image.getWidth()).thenReturn((int) width);
      Mockito.when(image.getHeight()).thenReturn((int) height);
      Mockito.when(image.getPlanes()).thenReturn(planes.toArray(new PlaneProxy[0]));
      byte[] result = api.getNv21Buffer(image);

      assertArrayEquals(expectedBytes, result);
      mockedStatic.verify(() -> ImageProxyUtils.planesToNV21(planes, (int) width, (int) height));
    }
  }
}
