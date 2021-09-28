---
layout: post
title:  "Introducing Dewobble 1.0.0"
date:   2021-09-28 23:14:00 +1000
description: Dewobble can stabilise shaky video from wide angle cameras, and simultaneously change the lens projection.
tags: ["Dewobble", "FFmpeg", "stabilization", "projection", "distortion", "barrel", "GoPro", "GPU", "OpenCL"]
categories: blogging
excerpt_separator: <!-- excerpt-end -->
---

{% include image.html url="assets/img/dewobble/dewobble-logo.png" description="Dewobble logo" caption="" max_width="240px" align="center" %}

After lots of research and [experimentation][post-transforming-opencv], multiple rewrites, and lots of optimization, version 1.0.0 of [Dewobble][dewobble-sourcehut] has been released! Dewobble is an open source C++ library (and accompanying FFmpeg filter, not yet released) that applies motion stabilisation and lens projection changes to videos. It's not the first software to do either of those things, even among FFmpeg filters, but it has a number of advantages over most existing solutions.

<!-- excerpt-end -->

In video form, here is what dewobble does:

{% include vimeo.html id="614305287" ratio="0.75" description="Going for a run with a GoPro strapped to my chest" %}

## The killer feature: no wobbling jelly

There are many other softwares that change lens projection of videos, including with FFmpeg as [I've previously written][post-lens-distortion]. There are also many other softwares that can do video stabilisation, like [vid.stab][vid.stab], or closed source video editors like Premiere Pro or Final Cut Pro.

However, almost all of them use affine based motion model. I'll explain more about this in a separate post, but the practical consequence is that they don't work very well for videos shot with a wide field of view and/or large camera movements. This is because they don't account for the way objects in the image are distorted when the lens is not facing directly towards them. The result is that there is a wobbling jelly like effect in the stabilised video, as the objects in the image are distorted in different ways depending on where the camera was facing.

Below is the most clear example of this I could produce. Dewobble and vid.stab are both configured with their fixed/tripod mode, which forces them to make large corrections even for slow camera movements. The grid makes the distortion obvious:

{% include vimeo.html id="616819895" ratio="0.375" description="Dewobble (left) vs vid.stab (right)" %}

Here's a comparison with a more realistic video. Notice that although vid.stab does a good job of detecting the average camera movement in each frame, the wobbling jelly effect is clearly visible as the camera moves (e.g. the horizon changes shape, and the trees sway sideways):

{% include vimeo.html id="614375877" ratio="0.375" description="Dewobble (left) vs vid.stab (right)" %}

Action cameras like GoPros have become very popular. Two of their distinguishing features are that they have a wide field of view, and are small and light. Because they are small and light, they can be attached to the body or to moving objects. In these situations, the camera movement is often noisy and the resulting video is very shaky. This severe shakiness and the wide field of view both present a problem for most video stabilisation software.

This is the use case that Dewobble is optimized for. Dewobble uses a rotation model of camera motion. When it detects and compensates for camera movement, it does so in terms of camera orientation in 3 dimensions, rather than in terms of a translations/rotations on a 2 dimensional plane. The result is that the accuracy does not degrade further from the center of the image, and therefore it can accurately detect and correct for large camera movements with a wide angle camera.

## Combined projection change and stabilisation

Another distinguishing feature of Dewobble is that it performs both projection changes and stabilisation at once (i.e. with a single pass of pixel interpolation). This has a number of advantages:
 - More efficient than 2 separate passes, therefore faster.
 - Reduces quality loss, since interpolation always results in some loss of information.
 - No cropping of intermediate frames (e.g. after stabilisation but before projection change). Every pixel is included as long as it can be mapped from the output to the input.

### Cropping of intermediate frames

In the similar example above, I've worked around the cropping issue by inserting borders in the input as a buffer, in order to avoid cropping the original input. This dramatically slows down the process because the intermediate frames need to be larger in order to accommodate the borders. Here is what the comparison looks like without that workaround. Notice that Dewobble never crops the input, whereas the combination of a stabilisation filter such as vid.stab with a separate projection change filter results in unnecessary cropping.

{% include vimeo.html id="614489679" ratio="0.375" description="Dewobble (left) vs vid.stab (right) &ndash; without cropping workaround" %}

## How to use it

### 1. Find the projection and field of view of your camera

Dewobble needs to know the projection and field of view (or focal length) of the camera. Fortunately, finding out this information is not as difficult as it may seem. Most cameras have a projection that is very close to the rectilinear projection (where straight lines in the real world remain straight in the image), or the fisheye projection. So if you took a guess at one of those, you would probably be right.

For the field of view, you may be able to look it up. GoPro publishes [tables with the field of view][gopro-fov-table] for their cameras. You may also find information about your camera in the extensive [Lensfun database][lensfun-db]. Failing that, you can measure it yourself by facing your camera towards a wall and doing some geometry. If you use Dewobble (or any other method) to convert to a rectilinear projection, you can also do a process of trial and error, adjusting the field of view setting until the output has straight lines. If you're comfortable compiling C++ code, you can also measure it very accurately using OpenCV. There's a [mini guide][measure-fov] for some of these methods in the README.

For example, I'm using a GoPro Hero 5 Black. I switch the picture mode to "4:3 Wide", and disable the camera's built in stabilisation (which crops the image, and effectively changes the field of view). The camera uses a fisheye projection, and has a 145.8&deg; field of view (diagonal, corner to corner).

### 2. Transform your video

#### Using the FFmpeg filter

The easiest way to use Dewobble is to use the FFmpeg filter that wraps it. My patch to add the Dewobble filter to FFmpeg hasn't yet been applied, but I hope soon it will be. In that case you will be able use it as follows:

```shell
$ ffmpeg \
    -init_hw_device opencl=ocl:0.0 -filter_hw_device ocl \
    -i INPUT \
    -vf 'format=nv12,hwupload,libdewobble=in_p=fish:in_dfov=145.8:out_p=rect:out_dfov=145.8,hwdownload,format=nv12' \
    OUTPUT
```

Let's break this down:

The first line of flags has `-init_hw_device opencl=ocl:0.0 -filter_hw_device ocl`. This is configuring an OpenCL device for Dewobble to use. You can change the `0.0` depending on which OpenCL implementation and device you want to use. Ideally you should use one that makes use of a GPU, since that will be much faster than a CPU. This choice won't affect the result, but it will affect the speed.

The second line specifies the input video. Then there is the video filter chain. `format=nv12,hwupload` uploads the video to your chosen OpenCL device, and afterwards `hwdownload,format=nv12` downloads it back to the CPU. If you want you can change these to avoid copying the video to the CPU, especially if you use hardware encoding or decoding. This also won't affect the result (in terms of what Dewobble does).

The important part is the Dewobble filter and its settings: `libdewobble=in_p=fish:in_dfov=145.8:out_p=rect:out_dfov=145.8`. What this sais is that the input video has a fisheye projection and a diagonal field of view of 145.8&deg;, and that the output should have the same projection. Stabilisation is applied by default, so the output will be smooth.

There are quite a few things you can change here if you want, besides providing the information about your camera (`in_p` and `in_dfov`):
 - You can change the output camera projection with `out_p` and `out_dfov`, which results in changing the projection. In most of the examples in this post, I used `out_p=rect:out_dfov=145.8`. Reducing the field of view is equivalent to zooming in or cropping.
 - You can turn off stabilisation if you only want to change projection by using `stab=none`. You can also use `stab=fixed` to maintain a fixed camera position (AKA tripod mode). With the default `stab=sg` you can adjust `stab_r` from the default 30 frames to control the "smoothness" of the output. The number is how many frames ahead/behind are considered when plotting a smooth camera path. `stab_h` controls how many consecutive frames will have their motion interpolated (i.e. guessed) in case it can't be detected.
 - You can change the output dimensions to differ from the input (`out_w` and `out_h`), and change where the center of the image is (`out_fx` and `out_fy`). In case your input isn't centered you can also specify the focal point in the input with `in_fx` and `in_fy`.
 - You can change the pixel interpolation method, which affects the quality of the output, using the `interp` option.
 - You can change how the borders are coloured (i.e. areas that the camera did not see) using the `border` and `border_rgb` options. If you don't like the default black borders, you can have the image reflected on the edges, replicated, or simply use a different colour.

#### Using the C/C++ library

You don't have to use Dewobble with FFmpeg. Headers are provided for C++ and C &ndash; see the [documentation][docs].

## Conclusion

I've had a great time writing Dewobble (which doesn't mean its finished!) and I plan to share more details about it in the near future. Coming up soon is a detailed explanation of how it works, and a more comprehensive comparison between Dewobble and other stabilisation software.

I wrote Dewobble to solve my own problems filming my team's dodgeball matches, and also as an experiment for my own learning and enjoyment. However I'd be happy to know if anybody else also finds it useful. I would love to hear from you if you decide to use it, or if you have any questions, suggestions, or patches. Happy dewobbling!


[dewobble-sourcehut]: https://git.sr.ht/~hedgepigdaniel/dewobble
[post-transforming-opencv]: {% post_url 2021-03-05-transforming-compressed-video-on-the-gpu-using-opencv %}
[post-lens-distortion]: {% post_url 2020-03-24-correcting-lens-distortion-with-ffmpeg %}
[vid.stab]: https://github.com/georgmartius/vid.stab
[measure-fov]: https://git.sr.ht/~hedgepigdaniel/dewobble#measuring-the-camera-field-of-view
[lensfun-db]: https://github.com/lensfun/lensfun/tree/master/data/db
[gopro-fov-table]: https://community.gopro.com/t5/en/HERO5-Black-Field-of-View-FOV-Information/ta-p/390131
[docs]: https://www.danielplayfaircal.com/dewobble/