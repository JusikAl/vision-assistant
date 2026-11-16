import java.nio.*;
import java.util.*;
import androidx.camera.core.ImageProxy.PlaneProxy;
import io.flutter.plugins.camerax.ImageProxyUtils;
public class NativeNv21PackingCheck {
 static class Plane implements PlaneProxy {
  final ByteBuffer bytes; final int row,pixel;
  Plane(byte[] bytes,int row,int pixel){this.bytes=ByteBuffer.wrap(bytes);this.row=row;this.pixel=pixel;}
  public ByteBuffer getBuffer(){return bytes;} public int getRowStride(){return row;} public int getPixelStride(){return pixel;}
 }
 public static void main(String[] args){
  int cases=0;
  for(int w=2;w<=20;w+=2) for(int h=2;h<=20;h+=2) for(int pad:new int[]{0,2,4}) for(int pixel:new int[]{1,2}){
   int ys=w+pad,us=w/2*pixel+pad;
   byte[] y=new byte[ys*(h-1)+w],u=new byte[us*(h/2-1)+(w/2-1)*pixel+1],v=u.clone();
   byte[] expected=new byte[w*h*3/2];
   for(int row=0;row<h;row++) for(int col=0;col<w;col++) expected[row*w+col]=y[row*ys+col]=(byte)(row*3+col*7);
   for(int row=0;row<h/2;row++) for(int col=0;col<w/2;col++){
    byte uv=(byte)(80+row+col),vv=(byte)(160-row-col);
    u[row*us+col*pixel]=uv;v[row*us+col*pixel]=vv;
    int i=w*h+row*w+col*2;expected[i]=vv;expected[i+1]=uv;
   }
   Plane yp=new Plane(y,ys,1),up=new Plane(u,us,pixel),vp=new Plane(v,us,pixel);
   yp.bytes.position(1); up.bytes.position(up.bytes.limit()); vp.bytes.position(vp.bytes.limit());
   List<PlaneProxy> planes=Arrays.asList(yp,up,vp);
   byte[] result=ImageProxyUtils.planesToNV21(planes,w,h).array();
   if(!Arrays.equals(expected,result))throw new AssertionError("packing w="+w+" h="+h+" pad="+pad+" pixel="+pixel);
   if(yp.bytes.position()!=1||up.bytes.position()!=up.bytes.limit()||vp.bytes.position()!=vp.bytes.limit())throw new AssertionError("source mutated");
   byte[] again=ImageProxyUtils.planesToNV21(planes,w,h).array();
   if(result==again||!Arrays.equals(result,again))throw new AssertionError("ownership/repeated conversion");
   cases++;
  }
  System.out.println("NATIVE PACKING PASS cases="+cases+" padded_rows=true source_positions_preserved=true independent_output=true");
 }
}