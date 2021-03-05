---
layout: post
title: "Transforming compressed video on the GPU using OpenCV"
date: 2021-03-05 20:20:00 +1100
category: blogging
tags: ["ffmpeg", "libavcodec", "VA-API", "opencv"]
description: Using OpenCV, OpenCL, and VA-API to transform a compressed video on the GPU.
---

In a [previous post]({% post_url 2020-03-24-correcting-lens-distortion-with-ffmpeg %}), I described various FFmpeg filters which I experimented with for the purpose of lens correction, and I mentioned I might follow it up with a similar post about video stabilisation. This post doesn't quite fulfill that promise, but at least I have something to report about GPU acceleration!

For background: videos that I recorded of my dodgeball matches had not only lens distortion, but also unwanted shaking. Sometimes the balls would hit the net that the camera was attached to, and the video became very shaky.

## Attempt 1: FFmpeg filter

The first thing I tried was to find an FFmpeg filter which could solve the problem. I found that the combination of [vidstabdetect][vidstabdetect] and [vidstabtransform][vidstabtransform] (wrappers for the [vid.stab][vid.stab] library) produced reasonably good results. However, this method had a number of issues:
 - It required 2 passes: one for detection of camera movement, and one to compensate for it.
 - It was very slow. The combination perspective remapping and the stabilisation  resulted in a framerate of about 3fps. This meant that a 40 minute dogeball match took half a day to process!
 - It created "wobbling" when the camera was shaking.

### Wobbling

The [model used by vid.stab][vid.stab-model] to represent the effect of camera movement is a limited affine transformation, including only translation, rotation, and scaling. In my application, the main way that the camera moved was by twisting &ndash; i.e. the camera remained at the same location, but it turned to face different directions as it shook. There was little rotation in practice, and little change in the position of the camera, so I don't think that vid.stab detected much rotation or scaling. Instead I think it applied translation (basically moving a rectangle in 2 dimensions) in order to correct for changes in the angle of the camera.

The problem is that translation is not what happens to the image when you twist a camera &ndash; what happens is a perspective transformation. Close to the center of the image or at a high zoom level translation is a good approximation, but it gets worse further away from the center of the image and with a wider field of view. My camera had a very wide field of view, so the effect was quite significant.


### Speed

There were a few reasons why the processing speed was so slow. One was that the expensive (and destructive) interpolation step was happening twice &ndash; once to correct for lens distotion, and then again for stabilisation. No matter how optimised the interpolation process was, this was a waste of time. In theory there is no reason not to perform the interpolation for both steps at once, but this wasn't supported by the FFmpeg filters, and probably wouldn't even make sense to do with the FFmpeg filter API.

Another opportunity was to use the GPU to speed up the tranformations. FFmpeg supports the use of GPUs with various APIs. The easiest thing to get working is compression and decompression. On Linux the established API for this is VA-API, which FFmpeg supports. I was already using VA-API to decompress the H.264 video from my GoPro camera, and to compress the H.264/H.265 output videos I was creating, but the CPU was still needed for the projection change and video stabilisation.

For more general computation on GPUs, there are various other APIs, including Vulkan and OpenCL. Although there are some FFmpeg filters that support these APIs, neither the lensfun or the vid.stab filters do. The consequence for me was that during the processing, the decoded video frames (a really large amount of data) had to be copied from the GPU memory to the main memory so that the CPU based filters could perform their tasks, and then the transformed frames copied back to the GPU for encoding.

This copying takes significant time. For example, I found that an FFmpeg pipeline which decoded and reencoded a video entirely on the GPU ran at about 380fps, whereas modifying that pipeline to copy the frames to the main memory and back again dropped this to about 100fps.

## Attempt 2: OpenCV

At this point I felt like I had exhausted my ability to solve the problem with scripts that called the FFmpeg CLI, and that to make more progress I would need to work at a lower level. Here are the tools I used:
 - libavformat, libavcodec, libavutil: C libraries for muxing/demuxing and encoding/decoding (part of FFmpeg)
 - OpenCV: An extensive library for computer vision written in C++
 - VA-API: Linux API for GPU video encoding and decoding
 - OpenCL: API for working with objects in GPU memory, well supported by OpenCV

I knew that there were methods in OpenCV to do things like perspective remapping, and that many of its more popular methods had implementations that operated directly on GPU memory with OpenCL. In order to take advantage of this, I needed to take the VA-API frames from the GPU video decoder and convert them to OpenCV `Mat` objects. To make the process run as fast as possible, I wanted to do this entirely on the GPU, without copying frames to the main memory at any point.

### Decoding with OpenCV VideoCapture

The first thing to do was to decode the input video and get VA-API frames. I first attempted to use OpenCVs [VideoCapture][VideoCapture] API to do so. Depending on the platform there is a [choice of backing APIs][capture-apis] from which to retrieve decoded video. The applicable choices were `CAP_FFMPEG`, and `CAP_GSTREAMER`. There weren't any [capture properties][capture-properties] in the OpenCV capture API at the time related to hardware decoding. While the FFmpeg backend only accepted a file path as input, the GStreamer backend also accepted a GStreamer pipeline. So with a bit of experimentation I came up with a GStreamer pipeline which decoded the video with VA-API (confirmed by running `intel_gpu_top` from [igt-gpu-tools][igt-gpu-tools]).

```c++
Mat frame;
VideoCapture cap(
    "filesrc location=/path/to/input.mp4 ! demux ! vaapih264dec ! appsink sync=false",
    CAP_GSTREAMER
);
while (true) {
    cap.read(frame);
    // Do stuff with frame
}
```

Although the decoding was done with VA-API, the resulting `frame` was not backed by GPU memory &ndash; instead the VideoCapture API copied the result to the main memory before returning it.

Aside: recently, [support for hardware codec props][props-hw] has been added to the VideoCapture and VideoWriter APIs. Although this would simplify using VA-API with the Gstreamer backend (and make it possible with the FFmpeg backend), it still doesn't return hardware backed frames. You can see the FFmpeg capture implementation [copying the data to main memory in `retrieveFrame`][ffmpeg-copy] and [vice versa in `writeFrame`][ffmpeg-copy-write]. Similarly in the GStreamer backend it looks like the buffer is [always copied to main memory in `retrieveFrame`][gstreamer-copy].

### Decoding with libavcodec

`VideoCapture` seemed like a dead end, so instead I turned my attention to demuxing and decoding the video with libavformat and libavcodec. Although this required a lot more code, I found that it worked very well. There are lots of examples in the documentation, including for hardware codecs, OpenCL, and mapping different types of hardware frames. I wrote code to open a file, and create a demuxer and video decoder. Then I set up a finite state machine to pull video stream packets from the demuxer and send them to the decoder, as well as code to pull raw frames from the decoder and process them. It was something like this pseudocode:
```
state = AWAITING_INPUT_PACKETS
while (state != COMPLETE):
    switch(state):
        case COMPLETE:
            break
        case FRAMES_AVAILABLE:
            while (frame = get_raw_frame_from_decoder()):
                process_frame()
            state = AWAITING_INPUT_PACKETS
            break
        case AWAITING_INPUT_PACKETS:
            if (input_exhausted()):
                state = COMPLETE
            else:
                send_demuxed_video_packet_to_decoder()
                state = FRAMES_AVAILABLE
            break
```

This was mostly the result of copying [examples like this one][hwdec-example] (except for the part that copies the VA-API buffer to main memory).


### Converting VA-API frames to OpenCL memory

With the VA-API frames available, it was time to convert them into OpenCL backed OpenCV `Mat` objects. OpenCL has an Intel specific extension [cl_intel_va_api_media_sharing][cl_intel_va_api_media_sharing] which allows VA-API frames to be converted into OpenCL memory without copying them to the main memory. Luckily I had an Intel GPU.

I could see two options for using this extension. One was to use [OpenCVs interop with VA-API][opencv-interop], and another was to first map from VA-API to OpenCL in libavcodec. On the first attempt with libavcodec I couldn't find a way to expose the OpenCL memory, so I chose the OpenCV VA-API interop option.

#### OpenCV VA-API interop

There were a few basic snags with OpenCV's VA-API interop. OpenCV is built without it by default, and the Arch Linux package doesn't include the necessary build flags. So I had to create a custom PKGBUILD and built it myself. In the process it became apparent that OpenCV was not compatible with the newer header provided by OpenCL-Headers, and only worked with the header from a legacy Intel specific package. So I had to also patch OpenCV to build with the more up to date headers (this is no longer necessary after [this recent fix to OpenCV][opencv-header-update]).

Making it work required some additional effort. The VA-API and OpenCL APIs both refer to memory on a specific GPU and driver, and also with a specific scope (a "display" in the case of VA-API and a "context" for OpenCL). So it's necessary to initialise the scope of each API such that the memory is compatible and can be mapped between the APIs. The easiest way seemed to be to choose a DRM device, use it to create a VA-API `VADisplay`, and then use this to create an OpenCL context (which the OpenCV VA-API interop handles automatically). The code looked something like this:

```c++
#include <opencv2/core/va_intel.hpp>
extern "C" {
    #include <va/va_drm.h>
}

void initOpenClFromVaapi () {
    int drm_device = open("/dev/dri/renderD128", O_RDWR|O_CLOEXEC);
    VADisplay vaDisplay = vaGetDisplayDRM(drm_device);
    close(drm_device);
    va_intel::ocl::initializeContextFromVA(vaDisplay, true);
}
```

The OpenCV API handles the OpenCL context in an implicit way - so after `initializeContextFromVA` you can expect that all the other functionality in OpenCV that uses OpenCL will use the VA-API compatible OpenCL context.

From there it was reasonably simple to create OpenCL backed `Mat` objects from VA-API backed `AVFrame`s:

```c++
Mat get_mat_from_vaapi_frame(AVFrame *frame) {
    Mat result;
    va_intel::convertFromVASurface(
        vaDisplay,
        frame->data[0], // <- If I remember correctly...
        dimensions,
        result
    );
    return result
}
```

This method worked, but it wasn't as fast as I had hoped. After reading the code I had a reasonably good idea why.

Video codecs like H.264 (and by extension APIs like VA-API) usually deal with video in NV12 format. NV12 is a semi planar format, which means instead of storing each pixel separately including all its colour channels, there are separate matrices to store the luminance/brightness of the whole image, and the chroma/colour (which incorporates 2 channels).

Also, OpenCL has [various different types of memory][cl-mem], and they cannot all be treated the same way. OpenCV `Mat` objects when backed by OpenCL memory use an OpenCL `Buffer`, whereas VA-API works with instances of `Image2D`. So in order to create a OpenCL backed `Mat` from a VA-API frame, it's necessary to first remap from an OpenCL `Image2D` to an OpenCL `Buffer`. What this means physically is dependent on the hardware and drivers.

The OpenCL VA-API interop handles both of these problems transparently. It maps VA-API frames to and from 2 `Image2D`s corresponding to the luminance (Y) and chroma (UV) planes, and it uses an OpenCL kernel to convert between these images and a single OpenCL Buffer in a BGR pixel format. Both of these steps take time, so the speed to decode a video and convert each frame to a `Mat` with a BGR pixel format was about 260fps, compared to about 500fps for just decoding in VA-API.

#### libavcodec hw_frame_map

The OpenCV VA-API interop worked, but required patches to OpenCV and its build script, and it took away control over how the NV12 pixel format was handled. So I took another stab at doing the mapping with libavcodec. libavcodec has a lot more options for different types of hardware acceleration and for mapping data between the different APIs, so I was hopeful that then or in the future there might be a way to do it on non Intel GPUs.

As the OpenCV VA-API interop did, it was necessary to derive an OpenCL context from the VA-API display so that the VA-API frames could be mapped to OpenCL. It was also necessary to initialise OpenCV with the same OpenCL context as the libavcodec hardware context so that they could both work with the same OpenCL memory.

```c++
// These contexts need to be used for the decoder
// and for mapping VA-API frames to OpenCL
AVBufferRef *vaapi_device_ctx;
AVBufferRef *ocl_device_ctx;

void init_opencl_contexts() {

    // Create a libavcodec VA-API context
    av_hwdevice_ctx_create(
        &vaapi_device_ctx,
        AV_HWDEVICE_TYPE_VAAPI,
        NULL,
        NULL,
        0
    );

    // Create a libavcodec OpenCL context from the VA-API context
    av_hwdevice_ctx_create_derived(
        &ocl_device_ctx,
        AV_HWDEVICE_TYPE_OPENCL,
        vaapi_device_ctx,
        0
    );

    // Initialise OpenCV with the same OpenCL context
    init_opencv_opencl_context(ocl_device_ctx);
}

void init_opencv_opencl_context(AVBufferRef *ocl_device_ctx) {
    AVHWDeviceContext *ocl_hw_device_ctx =
        (AVHWDeviceContext *) ocl_device_ctx->data;
    AVOpenCLDeviceContext *ocl_device_ocl_ctx =
        (AVOpenCLDeviceContext *) ocl_hw_device_ctx->hwctx;
    size_t param_value_size;

    // Get context properties
    clGetContextInfo(
        ocl_device_ocl_ctx->context,
        CL_CONTEXT_PROPERTIES,
        0,
        NULL,
        &param_value_size
    );
    cl_context_properties *props = malloc(param_value_size);
    clGetContextInfo(
        ocl_device_ocl_ctx->context,
        CL_CONTEXT_PROPERTIES,
        param_value_size,
        props,
        NULL
    );

    // Find the platform prop
    cl_platform_id platform;
    for (int i = 0; props[i] != 0; i = i + 2) {
        if (props[i] == CL_CONTEXT_PLATFORM) {
            platform = (cl_platform_id) props[i + 1];
        }
    }

    // Get the name for the platform
    clGetPlatformInfo(
        platform,
        CL_PLATFORM_NAME,
        0,
        NULL,
        &param_value_size
    );
    char *platform_name = (char *) malloc(param_value_size);
    clGetPlatformInfo(
        platform,
        CL_PLATFORM_NAME,
        param_value_size,
        platform_name,
        NULL
    );

    // Finally: attach the context to OpenCV
    ocl::attachContext(
        platform_name,
        platform,
        ocl_device_ocl_ctx->context,
        ocl_device_ocl_ctx->device_id
    );
}

```

Next, I attached the VA-API hardware context to the decoder context and configured the decoder to output VA-API frames:

```c++
// AVCodecContext *decoder_ctx = avcodec_alloc_context3(decoder);
// ...etc

// Attach the previously created VA-API context to the decoder context
decoder_ctx->hw_device_ctx = av_buffer_ref(vaapi_device_ctx);
// Configure the decoder to output VA-API frames
decoder_ctx->get_format = get_vaapi_format;

// This just selects AV_PIX_FMT_VAAPI if present and errors otherwise
static enum AVPixelFormat get_vaapi_format(
    AVCodecContext *ctx,
    const enum AVPixelFormat *pix_fmts
);

```

At this point the decoder was generating VA-API backed frames, so we could map them to OpenCL frames on the GPU:

```c++
AVFrame* map_vaapi_frame_to_opencl_frame(AVFrame *vaapi_frame) {
    AVFrame *ocl_frame = av_frame_alloc();
    AVBufferRef *ocl_hw_frames_ctx;

    // Create an OpenCL hardware frames context from the VA-API
    // frame's frames context
    av_hwframe_ctx_create_derived(
        &ocl_hw_frames_ctx,
        AV_PIX_FMT_OPENCL,
        ocl_device_ctx, // <- The OpenCL device context from earlier
        vaapi_frame->hw_frames_ctx,
        AV_HWFRAME_MAP_DIRECT
    );

    // Assign this hardware frames context to our new OpenCL frame
    ocl_frame->hw_frames_ctx = av_buffer_ref(ocl_hw_frames_ctx);

    // Set the pixel format for our new frame to OpenCL
    ocl_frame->format = AV_PIX_FMT_OPENCL;

    // Map the contents of the VA-API frame to the OpenCL frame
    av_hwframe_map(ocl_frame, frame, AV_HWFRAME_MAP_READ);

    return ocl_frame;
}
```

Internally, `av_hwframe_map` uses the same Intel OpenCL extension as the OpenCV VA-API interop. However libavcodec supports many other types of hardware, and for all I know there are or will be other options that work on non Intel GPUs. For example it might work to first convert to a DRM hardware frame, then then to an OpenCL frame.

Next we need to convert the OpenCL backed `AVFrame` into an OpenCL `Mat`:

```c++
Mat map_opencl_frame_to_mat(AVFrame *ocl_frame) {
    // Extract the two OpenCL Image2Ds from the opencl frame
    cl_mem luma_image = (cl_mem) ocl_frame->data[0];
    cl_mem chrome_image = (cl_mem) ocl_frame->data[1];

    size_t luma_w = 0;
    size_t luma_h = 0;
    size_t chroma_w = 0;
    size_t chroma_h = 0;

    clGetImageInfo(cl_luma, CL_IMAGE_WIDTH, sizeof(size_t), &luma_w, 0);
    clGetImageInfo(cl_luma, CL_IMAGE_HEIGHT, sizeof(size_t), &luma_h, 0);
    clGetImageInfo(cl_chroma, CL_IMAGE_WIDTH, sizeof(size_t), &chroma_w, 0);
    clGetImageInfo(cl_chroma, CL_IMAGE_HEIGHT, sizeof(size_t), &chroma_h, 0);

    // You can/should also check things like bit depth and channel order
    // (I'm assuming that the input is in NV12),
    // and you can probably avoid repeating this for each frame.

    UMat dst;
    dst.create(luma_h + chroma_h, luma_w, CV_8U);

    cl_mem dst_buffer = (cl_mem) dst.handle(ACCESS_READ);
    cl_command_queue queue = (cl_command_queue) ocl::Queue::getDefault().ptr();
    size_t src_origin[3] = { 0, 0, 0 };
    size_t luma_region[3] = { luma_w, luma_h, 1 };
    size_t chroma_region[3] = { chroma_w, chroma_h * 2, 1 };

    // Copy the contents of each Image2Ds to the right place in the
    // OpenCL buffer which backs the Mat
    clEnqueueCopyImageToBuffer(
        queue,
        cl_luma,
        dst_buffer,
        src_origin,
        luma_region,
        0,
        0,
        NULL,
        NULL
    );
    clEnqueueCopyImageToBuffer(
        queue,
        cl_chroma,
        dst_buffer,
        src_origin,
        chroma_region,
        luma_w * luma_h * 1,
        0,
        NULL,
        NULL
    );

    // Block until the copying is done
    clFinish(queue);

    return mat;
}
```

I made a different choice to the OpenCV VA-API interop in this case &ndash; rather than converting the image to the BGR pixel format immediately, I copied it in the simplest/fastest way possible, preserving the NV12 pixel format. This makes sense to me because there are many algorithms that operate only on single channel images anyway, so it seems pointless to throw away the luminance plane. If I want to convert the frame to BGR, then I can do so with [cvtColor][cvtColor], which also has an OpenCL implementation.

The combination of libavcodec mapping between VA-API and OpenCL hardware frames, OpenCL conversion from `Image2D` to `Buffer`, and `cvtColor` seems to be about as fast as the OpenCV VA-API interop.

### The video stabilisation part

Anyway, this was an interesting adventure. The next step is to actually use the OpenCV API to do the change in lens projection and video stabilisation. That requires some more experimentation, so I will leave this here for now. At least I'm confident that even a very slow implementation will be miles faster than the 3fps I started out with!

P.S. In case you really want to see the source code, [it's here](https://github.com/hedgepigdaniel/video-annotator/blob/6f9454c110b24eac5337e95176cacc02f5378c8f/opencv/DisplayImage.cpp) (probably in a mostly working state).


[vidstabdetect]: https://ffmpeg.org/ffmpeg-filters.html#vidstabdetect-1
[vidstabtransform]: https://ffmpeg.org/ffmpeg-filters.html#vidstabtransform-1
[vid.stab]: http://public.hronopik.de/vid.stab/
[vid.stab-model]: https://github.com/georgmartius/vid.stab/blob/f9166e9b082242b622b5b456ef80cbdbd4042826/src/transformtype.h#L30-L44
[opencv-interop]: https://docs.opencv.org/master/d5/d8c/va__intel_8hpp.html#ad534cae750fddc9ad30d0dc267deffa3
[opencv-header-update]: https://github.com/opencv/opencv/pull/18410
[cl_intel_va_api_media_sharing]: https://www.khronos.org/registry/OpenCL/extensions/intel/cl_intel_va_api_media_sharing.txt
[VideoCapture]: https://docs.opencv.org/master/d8/dfe/classcv_1_1VideoCapture.html#ac4107fb146a762454a8a87715d9b7c96
[capture-apis]: https://docs.opencv.org/master/d4/d15/group__videoio__flags__base.html#ga023786be1ee68a9105bf2e48c700294d
[capture-properties]: https://docs.opencv.org/master/d4/d15/group__videoio__flags__base.html#gaeb8dd9c89c10a5c63c139bf7c4f5704d
[props-hw]: https://github.com/opencv/opencv/pull/19460
[ffmpeg-copy]: https://github.com/opencv/opencv/blob/2e429268ff41dd616f45b5f4bdd16e225c69038d/modules/videoio/src/cap_ffmpeg_impl.hpp#L1392-L1402
[ffmpeg-copy-write]: https://github.com/opencv/opencv/blob/2e429268ff41dd616f45b5f4bdd16e225c69038d/modules/videoio/src/cap_ffmpeg_impl.hpp#L2178-L2201
[gstreamer-copy]: https://github.com/opencv/opencv/blob/2e429268ff41dd616f45b5f4bdd16e225c69038d/modules/videoio/src/cap_gstreamer.cpp#L459-L463
[hwdec-example]: https://ffmpeg.org/doxygen/4.1/hw_decode_8c-example.html
[cl-mem]: https://github.khronos.org/OpenCL-CLHPP/classcl_1_1_memory.html
[header-bug]: http://ffmpeg.org/pipermail/ffmpeg-cvslog/2020-March/121288.html
[igt-gpu-tools]: https://gitlab.freedesktop.org/drm/igt-gpu-tools
[cvtColor]: https://docs.opencv.org/master/d8/d01/group__imgproc__color__conversions.html#ga397ae87e1288a81d2363b61574eb8cab
