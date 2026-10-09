// Manual guest probe, compiled with Windows' bundled .NET Framework C# compiler.
// Requests HARDWARE and WARP explicitly, validates a rendered pixel and reports
// synchronous render + readback latency. These numbers are not game/presentation FPS.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

class Direct3DProbe {
    [DllImport("d3d11.dll", CallingConvention = CallingConvention.StdCall)]
    static extern int D3D11CreateDevice(IntPtr adapter, uint driver, IntPtr software, uint flags,
        uint[] levels, uint count, uint sdk, out IntPtr device, out uint level, out IntPtr context);
    [DllImport("d3dcompiler_47.dll", CallingConvention = CallingConvention.StdCall)]
    static extern int D3DCompile(byte[] source, UIntPtr size, string name, IntPtr defines, IntPtr include,
        string entry, string target, uint flags, uint effectFlags, out IntPtr code, out IntPtr errors);
    [StructLayout(LayoutKind.Sequential)] struct Texture {
        public uint width, height, mips, array, format, samples, quality, usage, bind, cpu, misc;
    }
    [StructLayout(LayoutKind.Sequential)] struct Viewport { public float x, y, width, height, min, max; }
    [StructLayout(LayoutKind.Sequential)] struct Mapped { public IntPtr data; public uint row, depth; }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint Release(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate IntPtr BufferPointer(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate UIntPtr BufferSize(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateTexture(IntPtr self, ref Texture desc, IntPtr initial, out IntPtr texture);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateView(IntPtr self, IntPtr resource, IntPtr desc, out IntPtr view);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateShader(IntPtr self, IntPtr code, UIntPtr size, IntPtr linkage, out IntPtr shader);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void SetShader(IntPtr self, IntPtr shader, IntPtr classes, uint count);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void SetTargets(IntPtr self, uint count, ref IntPtr view, IntPtr depth);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void SetViewport(IntPtr self, uint count, ref Viewport viewport);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void SetTopology(IntPtr self, uint topology);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void Draw(IntPtr self, uint vertices, uint first);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void Clear(IntPtr self, IntPtr view, float[] rgba);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void Copy(IntPtr self, IntPtr destination, IntPtr source);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int Map(IntPtr self, IntPtr resource, uint subresource, uint type, uint flags, out Mapped mapped);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void Unmap(IntPtr self, IntPtr resource, uint subresource);
    static T Method<T>(IntPtr obj, int slot) where T : class {
        return Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj), slot * IntPtr.Size), typeof(T)) as T;
    }
    static void Check(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }
    static void Free(IntPtr obj) { if (obj != IntPtr.Zero) Method<Release>(obj, 2)(obj); }
    static IntPtr Shader(IntPtr device, string source, string target, int slot) {
        IntPtr code = IntPtr.Zero, errors = IntPtr.Zero, shader;
        try {
            byte[] bytes = Encoding.ASCII.GetBytes(source);
            int result = D3DCompile(bytes, (UIntPtr)bytes.Length, "probe", IntPtr.Zero, IntPtr.Zero,
                "main", target, 1 << 15, 0, out code, out errors);
            if (result < 0 && errors != IntPtr.Zero)
                Console.Error.WriteLine(Marshal.PtrToStringAnsi(Method<BufferPointer>(errors, 3)(errors)));
            Check(result);
            Check(Method<CreateShader>(device, slot)(device, Method<BufferPointer>(code, 3)(code),
                Method<BufferSize>(code, 4)(code), IntPtr.Zero, out shader));
            return shader;
        } finally { Free(code); Free(errors); }
    }
    static void Run(uint driver, uint width, uint height, int draws) {
        IntPtr device = IntPtr.Zero, context = IntPtr.Zero, target = IntPtr.Zero, staging = IntPtr.Zero;
        IntPtr view = IntPtr.Zero, vs = IntPtr.Zero, ps = IntPtr.Zero;
        try {
            uint level;
            Check(D3D11CreateDevice(IntPtr.Zero, driver, IntPtr.Zero, 0, new uint[] { 0xb100, 0xb000 }, 2, 7,
                out device, out level, out context));
            Texture desc = new Texture { width = width, height = height, mips = 1, array = 1,
                format = 28, samples = 1, bind = 0x20 };
            Check(Method<CreateTexture>(device, 5)(device, ref desc, IntPtr.Zero, out target));
            Check(Method<CreateView>(device, 9)(device, target, IntPtr.Zero, out view));
            desc.usage = 3; desc.bind = 0; desc.cpu = 0x20000;
            Check(Method<CreateTexture>(device, 5)(device, ref desc, IntPtr.Zero, out staging));
            Method<SetTargets>(context, 33)(context, 1, ref view, IntPtr.Zero);
            Viewport viewport = new Viewport { width = width, height = height, max = 1 };
            Method<SetViewport>(context, 44)(context, 1, ref viewport);
            if (draws > 0) {
                vs = Shader(device, "float4 main(uint id:SV_VertexID):SV_Position { float2 p=float2((id<<1)&2,id&2); return float4(p*float2(2,-2)+float2(-1,1),0,1); }", "vs_5_0", 12);
                ps = Shader(device, "float4 main():SV_Target { return float4(1,0.25,0.125,1); }", "ps_5_0", 15);
                Method<SetShader>(context, 11)(context, vs, IntPtr.Zero, 0);
                Method<SetShader>(context, 9)(context, ps, IntPtr.Zero, 0);
                Method<SetTopology>(context, 24)(context, 4);
            }
            var clear = Method<Clear>(context, 50);
            var draw = Method<Draw>(context, 13);
            var copy = Method<Copy>(context, 47);
            var map = Method<Map>(context, 14);
            var unmap = Method<Unmap>(context, 15);
            float[] color = { 0.25f, 0.5f, 0.75f, 1 };
            double[] times = new double[20];
            for (int frame = -3; frame < times.Length; frame++) {
                var watch = Stopwatch.StartNew();
                clear(context, view, color);
                for (int i = 0; i < draws; i++) draw(context, 3, 0);
                copy(context, staging, target);
                Mapped mapped;
                Check(map(context, staging, 0, 1, 0, out mapped));
                try {
                    int at = checked((int)((height / 2) * mapped.row + (width / 2) * 4));
                    int[] expected = draws > 0 ? new int[] {255, 64, 32, 255} : new int[] {64, 128, 191, 255};
                    for (int i = 0; i < 4; i++) {
                        int actual = Marshal.ReadByte(mapped.data, at + i);
                        if (Math.Abs(actual - expected[i]) > 1)
                            throw new Exception("Pixel mismatch, channel " + i + ": " + actual + " expected " + expected[i]);
                    }
                } finally { unmap(context, staging, 0); }
                watch.Stop();
                if (frame >= 0) times[frame] = watch.Elapsed.TotalMilliseconds;
            }
            Array.Sort(times);
            Console.WriteLine("PASS driver={0} level=0x{1:x} size={2}x{3} draws={4} median_ms={5:F2} p95_ms={6:F2} pixel=verified",
                driver == 1 ? "HARDWARE" : "WARP", level, width, height, draws,
                (times[9] + times[10]) / 2, times[18]);
        } finally {
            Free(context); Free(ps); Free(vs); Free(view); Free(staging); Free(target); Free(device);
        }
    }
    static int Main() {
        try {
            foreach (uint driver in new uint[] { 1, 5 })
                foreach (uint height in new uint[] {720, 1080})
                    foreach (int draws in new int[] {0, 1, 32}) Run(driver, height * 16 / 9, height, draws);
            return 0;
        } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
