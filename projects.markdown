---
layout: page
title: Projects
permalink: /projects/
toc: true
description: A collection of open source projects that I've either created, maintained, or contributed to.
introduction: This is a collection of open source projects I've either created, maintained, or contributed to.
---

## Maintainership

These are projects which I maintain that have a significant community following, even though I didn't originally author them.

### DConf
[DConf](https://gitlab.gnome.org/GNOME/dconf) is a user settings database which is used as the backend for the GSettings API on linux systems. It is the primary way that GNOME apps store user settings on linux. I've maintained it since August 2018. This has involved:
 - reviewing and merging changes submitted by others
 - making regular releases
 - making improvements of my own, which have included various refactors and bugfixes. See my post [Running GNOME shell in Valgrind]({% post_url 2019-12-30-running-gnome-shell-in-valgrind %}) for a detailed account of some of them.

### Rudy
[Rudy](https://github.com/respond-framework/rudy) is a library that acts as the controller of a React/Redux app. It handles routing idiomatically by synchronising URLs with Redux actions, and provides an asynchronous middleware API for requests/routes, which works both during server side rendering and client side single page app transitions. I adopted an unfinished version of it which was written by James Gilmore, and have made various improvements since.
 - Improvements to development processes including introducing code review, CI testing, isolated unit tests, and documentation of changes.
 - Engaging with the community and encouraging contributions from others by adding documentation, engaging with issues, and reviewing and merging pull requests.
 - Implementation of middlewares to save and restore the browser scroll position when using the browser back/forward navigation.
 - Improvements to the developer experience, including the introduction of Typescript, linting, autoformatting, convenient scripts to create test releases, and automated changelog creation.
 - Refactoring and bugfixes related to the mirroring of the browser history stack, which addressed many outstanding bugs.
 - Conversion of the package into a monorepo, and factoring out of non-core functionality like setting the browser page title into separate packages that integrate using the middleware API.
 - Refactoring of the URL serialisation module to make the API more consistent and eliminate bugs related to string encoding.

## Authorship

These are projects which I created myself, either alone or with others.

### webpack-cloud-functions
[webpack-cloud-functions](https://github.com/hedgepigdaniel/webpack-cloud-functions) An integration for using webpack with cloud/lambda functions. Supports seamless HMR for local development and optimised bundles for production.

### webpack-error-on-warnings-plugin

[webpack-error-on-warnings-plugin](https://github.com/hedgepigdaniel/webpack-error-on-warnings-plugin) is a simple webpack plugin to fail builds in CI if there are warnings. Very similar to [webpack-errors-to-warnings-plugin](https://www.npmjs.com/package/warnings-to-errors-webpack-plugin), but written in Typescript.

### Mongo index analyzer
[Mongo index analyzer](https://github.com/hedgepigdaniel/mongo-index-analyser) is a script which runs in the MongoDB shell and queries the system profile collection and find the most inneficient operations. An interesting experiement, which helped me to learn about how mongo serves queries and what query patterns are problematic.

### Video annotator
[video-annotator](https://github.com/hedgepigdaniel/video-annotator) is a very experimental tool for video processing. I wrote it to process video of Dodgeball matches, which I play for fun. There are two versions:
 - A Node.js CLI script which wraps FFmpeg and can do lens distortion correction (e.g. for GoPro fisheye lenses), video stabilisation, and all while using as much hardware acceleration as possible
 - A C++ version (very much a work in progress) which uses libavcodec, OpenCL, and OpenCV to perform a similar task, but hopefully more flexibly than with FFmpeg, with better motion stabilization, and faster due to less memory copying and better use of hardware acceleration.

### Panko
[Panko](https://github.com/hedgepigdaniel/panko) is an unfinished blockchain app built on Ethereum with the Truffle framework. It allows the user to upload a file and have its hash posted on the Etherum blockchain, thereby proving that that user had access to the file at a certain time.

## Contribution

### webpack
webpack is a bundler for Javascript and other client side assets. My contributions were:
 - a [fix](https://github.com/webpack/webpack/pull/7039) for peer dependency warnings
 - a [performance improvement](https://github.com/webpack/webpack/pull/9719) which significantly increased the speed of watching recompilations in large projects.

### Haul
Haul is a library which wraps webpack such that it can be used to compile react-native apps. I've made various contributions:
 - A simple [fix](https://github.com/callstack/haul/pull/406) to address dependency warnings and issues
 - Adding [support for react-native 0.57](https://github.com/callstack/haul/pull/477), which involved refactoring internal Babel plugins following breaking changes in Babel 7, accounting for changes in Haste module resolution (and the resulting assumptions in the react-native Javascript library), changes in the react-hot-loader API, and more.
 - A [fix](https://github.com/callstack/haul/pull/462) for a bug which prevented debugging from working in certain configurations.
 - A [fix](https://github.com/callstack/haul/pull/704) for a bug which broke production builds with sourcemaps if there was a dynamic ES6 import in the source code.

### FFmpeg
The FFmpeg project includes libraries for handling audio visual media. My contributions were:
 - The [addition of a scale parameter](https://lists.ffmpeg.org/pipermail/ffmpeg-cvslog/2019-March/117191.html) for the lensfun filter.
 - A [fix](https://patchwork.ffmpeg.org/project/ffmpeg/patch/20200316012046.92191-1-daniel.playfair.cal@gmail.com/) for a missing header file in releases.

### Linux kernel
The linux kernel is the main open source operating system kernel. I sent a [fix](https://github.com/torvalds/linux/commit/538f67407e2c0e5ed2a46e7d7ffa52f2e30c7ef8) for spurious interrupts coming from the touchpad on a particular laptop after resuming from suspend, which caused degraded battery life.

### scroll-behavior
scroll-behaviour is a library to save and restore scroll positions in single page apps, while accounting for various browser API differences. It was originally used in react-router, and is now used in Rudy. I've made various contributions:
 - the [addition](https://github.com/taion/scroll-behavior/pull/287) of Typescript types.
 - [A new API](https://github.com/taion/scroll-behavior/pull/306) to pause the saving of the scroll position in order to ensure accuracy of the saved position when transitions are not instant (e.g. if the UI does not fully render until an API call completes).
 - A [fix](https://github.com/taion/scroll-behavior/pull/293) for a bug where the scroll position was incorrectly assumed to be 0 before any scrolling was performed.
 - A [refactor](https://github.com/taion/scroll-behavior/pull/344) to remove the usage of the problematic `before-unload` browser API, which prevents page caching in browsers.

### circular-dependency-plugin
circular-dependency-plugin is a webpack plugin to generate a warning when there is a circular dependency between modules. My contributions were:
 - A [new option](https://github.com/aackerman/circular-dependency-plugin/pull/37) to not generate warnings for circular dependencies when some of the imports were asynchronous. Asynchronous import cycles don't have the symptom that correct imports can be undefined at runtime.
 - A [performance optimization](https://github.com/aackerman/circular-dependency-plugin/pull/49) to replace the existing algorithm to find import cycles with Tarjan's strongly connected components algorithm.

### loadable-components
loadable-components is a set of libraries for code splitting and server side rendering of React components. My contributions were:
 - Adding [support for components in named exports](https://github.com/gregberge/loadable-components/pull/483) in asynchronously imported modules.
 - The [addition of a script](https://github.com/gregberge/loadable-components/pull/486) to make test releases as github tags (something which is not easy in a monorepo).
 - The addition of a [new option](https://github.com/gregberge/loadable-components/pull/487) to avoid calling the expensive `stats.toJson()` function, which significantly increases watching recompile speed in large projects.

### Django-prometheus
Django-prometheus is a library to integrate the Django web framework with prometheus monitoring system. I sent a [fix](https://github.com/korfuri/django-prometheus/pull/51) for a bug which caused file upload requests to fail following breaking changes in Django.

### Pymongo
Pymongo is the official MongoDB client library for Python. I sent a [fix](https://github.com/mongodb/mongo-python-driver/pull/300) for a bug which prevented values read from the database from being deserialised with the correct timezone awareness.

### Socketcluster
Socketcluster is a protocol and libraries which provide a publish/subscribe API over HTTP websockets. I sent a [fix](https://github.com/SocketCluster/socketcluster-client/pull/23) to the browser Javascript client for an incompatibility between two features - the ability to automatically reconnect to subscribed channels following a connection dropout, and the ability to manually choose when subscriptions are persisted to the server following socket connection.

### react-native-maps
react-native-maps is a react-native component for displaying an interactive map. I sent a [refactor](https://github.com/react-native-community/react-native-maps/pull/1982) to make use of static ES6 exports rather than commonJS exports. This has many advantages, among them compile errors when imported names are misspelled, easier type checking, and better dead code elimination.

### Reductive
Reductive ReasonML library for app state management, which emulates Redux. My contribution was to [explain a misunderstanding](https://github.com/reasonml-community/reductive/issues/24) which impacted the names in its API. This led to the API being improved by others later.

### gnome-shell-extension-freon
gnome-shell-extension-freon is an extension for the GNOME shell which adds a status bar icon to display system state such as temperatures and fan speeds. My contribution was a [fix](https://github.com/UshakovVasilii/gnome-shell-extension-freon/pull/72) for a bug where the API of a destroyed object was used, resulting in a shell crash.

### redux-thunk
redux-thunk is a library for creating thunks which can be dispatched as redux actions. I sent a [fix](https://github.com/reduxjs/redux-thunk/pull/251) for a missing peer dependency.

### react-static
react-static is a static site generator for React. I sent a [refactor](https://github.com/react-static/react-static/pull/688) to avoid transpiling all code in a project to commonJS. This involved changes to the generated webpack and Babel configurations, a new option to optionally disable the behaviour, and a change to generate compile errors in the case that a project imported a name from a file that was not exported (e.g. due to a misspelling).
