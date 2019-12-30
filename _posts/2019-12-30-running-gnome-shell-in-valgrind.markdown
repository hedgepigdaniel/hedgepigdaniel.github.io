---
layout: post
title:  "Adventures making gnome-shell run in Valgrind: part 1"
date:   2019-12-30 20:13:20 +1100
categories: [blogging, gnome, dconf]
description: My adventures debugging crashes and hangs when running gnome-shell in Valgrind, and tracing them to spurious changed signals emitted from DConf
---

There is a nasty sort of bug that can occur in languages without memory safety - bugs where memory is accessed incorrectly. There are a few reasons why these bugs are nasty, worse than many other types of bugs:
 - The consequences are often severe (usually the entire process crashes, or worse behaves unpredictably).
 - They often create security vulnerabilities.
 - They are difficult to debug. The symptoms may appear intermittently, and may manifest far away from the cause.

## gnome-shell crashes

I came across such a bug in gnome-shell soon after the release of GNOME 3.24 in 2017. The symptom was that the gnome-shell process would crash a few times a day, at seemingly random times. Since I was using it as a Wayland compositor, this resulted in the entire session and all applications being closed. I was proud of my setup, having spent a few years working out how to completely avoid using Windows, and with a Linux setup using Wayland. Therefore, this bug was extremely annoying, and filled me with rage and an irrational desire to find and correct the problem at any cost.

First I [reported][Arch bug report] the bug to the Arch Linux bug tracker. It was clear from the stacktrace that the crash was occuring in GJS, which is the GNOME Javascript runtime. Jan de Groot, the maintainer of the GJS package in Arch Linux, provided some test builds with different compilation flags, but these didn't fix the problem. Soon after, a patch was provided by Philip Chimento, the upstream maintainer of GJS, to fix some memory access issues which he thought might be causing the bug. Some other users were satisfied that the problem was solved, but in my case the crashes kept happening. At this point it was clear to me that the problem did not lie in Arch Linux in particular, so I decided to engage with GJS upstream to try to debug the issue.

In order to make useful bug reports, I had to learn how to do a few things:
 - Compile packages from source in Arch Linux, especially with debug symbols (so that stacktraces contained locations in source code, not hex addresses in binary blobs), and with patches (to test bugfixes).
 - Read system logs efficiently (filtering by unit, showing logs only from the last boot, etc).
 - Read coredump files to extract stacktraces from crashed process dumps
 - Use GDB to attach to a running process and examine the state in the event of a crash
 - Switch TTYs in order to use a terminal even if the entire shell/UI was unusable for some reason (e.g., it was paused on a breakpoint)

Over the next few weeks, there were [various][GJS shell crash 0] [bug][GJS shell crash 1] [reports][GJS shell crash 2] of similar shell crashes. A series of patches appeared to fix the majority of those problems. All of these problems were intermittent and difficult to reproduce, and in most cases it appeared that the best the developer could do was to guess the cause and ["[throw] patches into the void to see if they stick"][the void].

## Valgrind

I don't write much C code, but I remember that in first year university I learned how to debug improper memory access with [Valgrind][Valgrind]. Valgrind runs your program and instruments memory access and allocation, providing warnings when your program accesses memory in incorrect or suspect ways. Where without Valgrind bad memory access *might* cause a program to crash in unrelated code some indeterminate time in the future, with Valgrind it would cause an error to be logged immediately, including a stacktrace of the bad memory access. It's hard to overstate how useful Valgrind is in these cases.

There were two particular shell crash bugs which affected me and appeared to be the most difficult to fix, and on both those tickets the [developers][Valgrind request 2] [suggested][Valgrind request 3] that users who were able to reproduce the bug should run the shell under Valgrind and post a log. This would provide a clear indication to the developer of what caused the problem, even if they were not able to easily reproduce the bug.

This sounded easy - find the command used to run the shell, and put `Valgrind` in front of it. Unfortunately, it was not so simple:
 - code in various packages called from the same process triggered enormous quantities of Valgrind warnings. All these packages had to be compiled from source with the `--enable-valgrind` argument to `configure` or similar. This made the compiled binaries include special Valgrind annotations with exceptions for code that intentionally did things that triggered Valgrind warnings. In some cases that didn't work and it was necessary to find a Valgrind suppression file elsewhere and use it manually when running Valgrind.
 - Running the shell directly did not have the same effect as running it from within a session (gnome-session). To have the shell work normally, it was necessary to create a session that ran the shell in Valgrind.
 - When gnome-shell was run as normal but in Valgrind, it tended to crash or hang and fail to start successfully. It turned out that the crashes/hangs happened reliably when the [taskbar shell extension][taskbar] was in use - and also that the shell crash only happened when it was in use.

The first two problems were easily (if tediously) solveable, but the hangs/crashes presented a more significant barrier. How to debug a problem if the debugging tools prevent the problem from hapenning? I wasn't the only user with this problem - [other][slow Valgrind 2] [users][slow Valgrind 3] also reported that they tried and failed to collect a Valgrind log because the shell simply hung forever.

This was sad to see - I assume that very many users had experienced the crash. A small proportion had found the stacktrace and looked up one of the bug reports. A smaller proportion had contributed useful information to them, and still less had attempted to reproduce the bug in Valgrind. These users could have provided the necessary information to solve the issue, but even that much effort was fruitless because Valgrind couldn't easily be made to work.

## A new quest

This problem was demoralising but also motivational. I didn't understand the inner workings of GJS or SpiderMonkey and was not in a position to understand or solve the specific problems that were causing these crashes. But I could see that the inability of users to collect Valgrind logs presented a significant barrier to fixing the issues. This would also be the case for any other bug caused by bad memory access in the gnome-shell process (which was alot of bugs, most of them very bad bugs).

So my new quest was to discover why the shell did not run correctly under Valgrind. Nobody else seemed to know why that was the case or have enough time and interest to investigate it. I thought perhaps this could be evidence of deeper issues (code that doesn't work in Valgrind probably doesn't work reliably in general). Also, I thought that this was the underlying problem leading to the crashes, in a sense. There were various bugs observable in normal use and most of them were not directly caused by the Valgrind problem, but they were all difficult to fix as a result of the Valgrind problem, so in the long term the best path to fix such crashes was to fix the Valgrind issues so that memory access bugs could be diagnosed more easily.

To continue my investigation, I had to learn the relationship between a number of projects that seemed related to this issue (and who's code ran in the problematic gnome-shell process):
 - [DConf][dconf]: key/value database used for storing, reading, and subscribing to changes in user settings.
 - [GSettings][gsettings]: Wraps DConf (at least on Linux) and provides a cross platform API for reading, writing, and subscribing to changes in user settings. This is the standard API used for this purpose in GNOME.
 - [GJS][gjs]: The GNOME Javascript interpreter. Uses SpiderMonkey to run javascript in GNOME projects, and adds extra APIs including an interface to GSettings.
 - [gnome-shell][gnome-shell] and extensions: Implement the shell UI. Mostly the UI code is written in javascript, which is run by GJS, and uses the GSettings API to access user settings.

Also, I had to learn a few more debugging techniques:
 - Valgrind can be run such that it integrates with GDB, and provides breakpoints when bad memory access occurs (using the `--vgdb` flag)
 - Valgrind has a `--track-fds` option, which logs a stacktrace whenever a file is opened
 - A stacktrace of the Javascript code in gnome-shell can be obtained from a running process by using the `gjs_dumpstack` function in GDB. This provides higher level context of what the process is doing (e.g. creating a clock widget as opposed to freeing a Javascript closure).

## Symptom 1: immediate crash

The most easily reproduceable problem when running the shell in Valgrind was a crash that occured immediately after starting the shell, before the UI was visible. I found two [open][xkb crash 1] [tickets][xkb crash 2] about similar issues with the same stacktrace (i.e. crashes in normal use, without Valgrind). I also found [other][old xkb 1] [tickets][old xkb 2] going back at least a year (all unsolved) with similar symptoms and the same stacktrace. The stacktrace looked something like this:

```
#0 xkb_keymap_ref at src/keymap.c:59
#1 clutter_evdev_set_keyboard_map at evdev/clutter-device-manager-evdev.c:2399
#2 meta_backend_native_set_keymap at backends/native/meta-backend-native.c:427
```

In most of these cases, the issue was intermittent, and seemed to depend on the shell extensions installed. So it seemed like I had stumbled upon an opportunity, because I could reproduce the problem 100% reliably with Valgrind.

I posted more detailed information about how I debugged the cause starting from [this comment][xkb debug process]. What I discovered after alot of breakpoints and calls to `gjs_dumpstack` was that:
 - The crash occurred because a system call to create a timer was failing with `EMFILE` (too many open files)
 - This timer was being opened in order to instantiate a `Gnome.WallClock` widget in JS land
 - The `Gnome.WallClock` was being instantiated inside a callback for when user settings are changed
 - The open files limit was reached primarily because instances of `Gnome.WallClock` were instantiated repeatedly until the limit (on my system, 1024) was reached

I felt that I was a step closer to understanding the problem, but It was not clear to me why that callback was being run so many times (Why would anyone want 1024 clock widgets? Why would a setting be changed 1024 times without any user input?). Without Valgrind, only a handful of the clock widgets were instantiated.

At least now I had a way of working around the problem. If I commented out the code that instantiated a `Gnome.WallClock`, the issue dissappeared. So I did that temporarily, and moved on to the next problem.

## Symptom 2: hangs

The next problem was that the shell would hang when run in Valgrind with the taskbar extension enabled, and never reach the state where the UI was visible. The gnome-shell process was using 100% of a CPU core, so I assumed that the hang was caused by some sort of infinite loop.

I created a [bug report][hang 1] for this behaviour. With alot of help from Philip Chimento I was able to use a mixture of pausing the process in GDB, breakpoints, `gjs_dumpstack`, and JS log statements to find the loop (or at least, the most obvious loop). There is a DConf setting `disable-extensions` which controls whether or not to disable shell extensions that are not verified to work with the current gnome-shell version. There is code in gnome-shell that responds to changes of that setting. When it changes, all extensions are disabled, and then the appropriate set of extensions is enabled again.

The problem was that the signal handler attached to changes of this setting was being called even though the setting had not actually changed. The loop happened because something that ran in the signal handler (e.g. in the process of disabling and reenabling all shell extensions) caused the original signal to be emitted again. The result was that the shell entered an infinite loop of disabling and reenabling all of the shell extensions.

Subsequently I discovered an [existing bug report][btrfs hang] detailing a hang when running gnome-shell with the taskbar extension enabled on a BTRFS file system. My guess was that this was the same issue, and that in the right set of circumstances it could be triggered in normal use, without Valgrind.

This discovery threw new light onto the first symptom. After investigating that symptom further, it became clear that a similar issue was to blame. Signal handlers were called to handle changed settings even though the settings had not changed, and they were called (directly or indirectly) from inside the same signal handlers. It just so happenned that one of the things done in one of the signal handlers involved creating a timer, and as a result hitting the open file limit was the first thing to break.

## Symptom 3: duplicated UI widgets

When running the shell in Valgrind with the workaround for the `xkb_keymap_ref` crash and with the taskbar extension disabled, I also noticed that one of the widgets created by another of my shell extensions was duplicated many times. Instead of there being one item on the status bar with CPU temperatures, there were several. This wasn't a large problem, but it later turned out that it was related.

## Fixing the bug

At this point I had found the nature of these various bugs and could explain why they occured. What remained was to determine how best to fix the problem.

The most obvious solution was to follow a pattern that had already been used in most cases in the gnome-shell Javascript code, save for a few exceptions. Any callback to a signal about changed settings should first read the new value and check if it was different from the previous value, and return early if it had not changed, thereby avoiding any side effects. In this [bug report][extensions hang] about the disable/enable extensions loop I posted some patches that did this. They solved the problem at least in some cases, but they didn't seem like a good solution for a few reasons:
 - They complicated the JS code, because whenever a signal handler was used, the value of the settings being listened to had to be stored in JS, duplicating the existing state in DConf.
 - They required all JS code run in the shell (including code in third party extensions) to consistently perform these checks. Even if I did find and fix all the problematic callbacks in gnome-shell and in all of the extensions available today, the problem would probably return in the future when new callbacks were added, and people assumed that a changed signal meant that a setting had actually changed.
 - They felt like a workaround made at the wrong level of abstraction. Why should high level single threaded JS code need to workaround spurious signals caused by compromises in multiprocess C code?

My next thought was to go one level down the stack, to GJS and its wrapped version of the Gio/GSettings API. I suggested that similar checks should be performed transparently in GJS so that signals were only sent to client code when the values had changed. Philip did not like this idea because it would mean that the GJS interface to Gio/GSettings would no longer be a thin wrapper with no added behaviour, and would instead be a different API with different behaviour, requiring separate documentation. This approach would increase the complexity of the system. This assessment seemed reasonable to me. So I turned my attention deeper into the stack.

## Finding the cause of the spurious signals

The various symptoms I had come across were not all triggered in the same way, as far as DConf/GSettings were concerned. I made two bug reports against GSettings:
 - [spurious changed signals about specific keys][spurious 1] (two different types of stacktraces)
 - [spurious changed signals about all keys at once][spurious 2]

At the time, DConf was (arguably) unmaintained. The original author and maintainer Allison Karlitskaya (formerly Allison Lortie, Ryan Lortie) appeared to have moved on from the project, and the only recent changes were related to the build system and not to functionality. Luckily two of the Glib maintainers, Mathias Clasen and Philip Withnall, helped me out. Mathias reviewed one of my patches, and Philip put me in contact with Allison, who reviewed one of the other patches. The first set of patches solved the problem, but also introduced other issues, from memory leaks to potential database consistency bugs.

As a brief aside, DConf has the following architecture (simplified, as is relevant):
- There is a single writer service, which maintains the canonical database state and is solely responsible for making changes to the database and writing it to disk. It responds to requests sent over D-Bus to change settings, and emits signals over D-Bus when settings change.
- There is a library called "engine" that can be linked with client software to access the database. Reads are done directly from the database on disk, while requests to write or to subscribe to changes are submitted over D-Bus to the writer service.
 - The engine library presents an optimistic (as in, optimistic concurrency) API to GSettings. Reads are synchronous and are handled within the same thread/process, but writes and subscribe requests also succeed immediately - before the central writer service has received and responded to the request.

With the help of Allison's feedback, particularly relating to DConf's consistency model, I identified 3 distinct fixable issues which caused spurious changed signals, and wrote a patch to address each:
 1. The central writer service emitted changed signals for keys that were written, even if the new value was the same as the old value. The fix was to not do that.
 1. The engine library emitted changed signals optimistically when write requests were made from that process, even if the new value was the same as the old value (according to that process's view of the database). Again the fix was to not do that.
 2. The engine library emitted changed signals for all keys in the database if a write occured in between when a subscription was requested and when it was confirmed by the writer service (because of the possibility that the change should have caused a signal, but didn't because the writer service had not yet created the subscription). The fix was to keep track of keys with in progress subscription requests in the engine, and emit changed signals only for those keys in this case.

## Bug fixed!

These fixes didn't make it impossible for spurious changed signals to occur, but they made it much less likely, and even less likely for an infinite loop to occur as a result. I think they make it impossible for an infinite loop to occur unless the client code repeatedly sets keys to different values, or repeatedly subscribes and unsubscribes to the same key while writes are submitted at the same time (since otherwise an equilibrium would always be reached at a certain set of values and subscriptions).

With all of these patches, I could run gnome-shell in Valgrind with the taskbar extension enabled, and it worked normally. Also, startup time was significantly faster on account of not repeatedly enabling and disabling all extensions on startup (which previously happened 2-4 times on each startup even without Valgrind). I also found that the third symptom of duplicated UI widgets was gone, and presumeably also a [similar issue][caja] with the Caja extension which had previously been traced to spurious GSettings signals.

## Releasing the fixes

Having written these patches, confirmed that they fixed the problem, and reaching what I thought was a good enough consensus that they were the right approach, It seemed to me that the only thing left was to test them thoroughly, and to have them merged and released.

What followed was a longer and harder process than I expected - a process which is still ongoing. Part 2 of this post will go into the details of how I managed to have some of those patches released, and what still remains to merge the others.

The situation today is that the patch for issue 3 (see above) was merged in [this pull request][pending patch 1], along with a subsequent [follow up pull request][pending patch 2]. These changes were released in GNOME 3.30 in 2018-09, and it appears that they were enough to solve the `xkb_keymap_ref` crash, which [hasn't been reopened since][gitlab xkb]. I've just [merged the pull request][service patch] to solve issue 1, which is now on track to be released in GNOME 3.36 in 2020-03. Issue 2 is addressed by [another pull request][engine patch] which still requires some cleanups before it can be merged.

## Reflection

The original intermittent crash (or at least one of them) remained present for many months and caused me (and probably others) great annoyance. It was eventually fixed separately from my adventures with DConf. I don't know exactly when, how, or by who, but I stopped experiencing it I think after the release of GNOME 3.26.

I hope that when all these fixes to DConf are released, and running gnome-shell in valgrind works without issue, that debugging similar problems is easier than it was when I experienced them. I'm glad that in this process I solved various other issues in GNOME that had been difficult to debug and had significantly detracted from the experience of many of its users.

Besides that, I'm glad to have been through this mad goose chase, and to have learned everything that I needed to learn along the way. Much of that knowledge and experience has been useful to me in other ways since.

## Acknowledgements

Thankyou to [Philip Chimento (ptomato)][ptomato], [Allison Karlitskaya (desrt)][desrt], [Philip Withnall (pwithnall)][pwithnall], and [Mathias Clasen (mclasen)][mclasen] for the help and encouragement they gave me during this process. I couldn't have done it without them.

[Arch bug report]: https://bugs.archlinux.org/task/53582#comment156598
[GJS shell crash 0]: https://bugzilla.gnome.org/show_bug.cgi?id=781194
[GJS shell crash 1]: https://bugzilla.gnome.org/show_bug.cgi?id=781799
[GJS shell crash 2]: https://bugzilla.gnome.org/show_bug.cgi?id=783935
[Valgrind request 2]: https://bugzilla.gnome.org/show_bug.cgi?id=783935#c10
[slow Valgrind 2]: https://bugzilla.gnome.org/show_bug.cgi?id=783935#c11
[GJS shell crash 3]: https://bugzilla.gnome.org/show_bug.cgi?id=785657
[the void]: https://bugzilla.gnome.org/show_bug.cgi?id=785657#c20
[Valgrind request 3]: https://bugzilla.gnome.org/show_bug.cgi?id=785657#c97
[slow Valgrind 3]: https://bugzilla.gnome.org/show_bug.cgi?id=785657#c73

[old gsettings bug]: https://bugzilla.gnome.org/show_bug.cgi?id=721590

[xkb crash 1]: https://bugzilla.redhat.com/show_bug.cgi?id=1441490
[xkb debug process]: https://bugzilla.redhat.com/show_bug.cgi?id=1441490#c21
[xkb crash 2]: https://bugzilla.gnome.org/show_bug.cgi?id=782688
[old xkb 1]: https://bugzilla.redhat.com/show_bug.cgi?id=1349265
[old xkb 2]: https://bugzilla.redhat.com/show_bug.cgi?id=1398142

[hang 1]: https://bugzilla.gnome.org/show_bug.cgi?id=786186
[extensions hang]: https://bugzilla.gnome.org/show_bug.cgi?id=788110
[btrfs hang]: https://bugzilla.redhat.com/show_bug.cgi?id=1464294

[Valgrind]: https://Valgrind.org/
[taskbar]: https://github.com/zpydr/gnome-shell-extension-taskbar
[dconf]: https://gitlab.gnome.org/GNOME/dconf
[gsettings]: https://developer.gnome.org/GSettings/
[gjs]: https://gitlab.gnome.org/GNOME/gjs
[gnome-shell]: https://gitlab.gnome.org/GNOME/gnome-shell/

[spurious 1]: https://bugzilla.gnome.org/show_bug.cgi?id=789639
[spurious 2]: https://bugzilla.gnome.org/show_bug.cgi?id=790640
[caja]: https://bugzilla.gnome.org/show_bug.cgi?id=721590

[pending patch 1]: https://gitlab.gnome.org/GNOME/dconf/merge_requests/1
[pending patch 2]: https://gitlab.gnome.org/GNOME/dconf/merge_requests/5
[service patch]: https://gitlab.gnome.org/GNOME/dconf/merge_requests/3
[engine patch]: https://gitlab.gnome.org/GNOME/dconf/merge_requests/2
[gitlab xkb]: https://gitlab.gnome.org/GNOME/mutter/issues/76

[ptomato]: http://ptomato.name/
[desrt]: https://gitlab.gnome.org/desrt
[pwithnall]: https://tecnocode.co.uk/
[mclasen]: https://blogs.gnome.org/mclasen/