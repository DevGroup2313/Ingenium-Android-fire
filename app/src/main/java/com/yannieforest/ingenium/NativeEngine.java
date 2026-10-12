/*
   INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
   NO LICENCE IS GRANTED. See LICENCE.txt.

   The native engine (llama.cpp, built for this device). Text crosses as UTF-8
   bytes. Every call except abort() must come from the one engine thread.
*/
package com.yannieforest.ingenium;

final class NativeEngine {

    interface Callback {
        /** kind 0 = answer text, kind 1 = the model's reasoning ("thinking") */
        void onPiece(int kind, byte[] utf8);
        /** load progress 0..1; return false to cancel the load */
        boolean onProgress(float progress);
    }

    static final boolean available;
    static final String loadError;

    static {
        boolean ok = false;
        String err = null;
        try {
            System.loadLibrary("ingenium");
            init();
            ok = true;
        } catch (Throwable t) {
            err = String.valueOf(t);
        }
        available = ok;
        loadError = err;
    }

    private NativeEngine() {}

    static native void init();
    static native String version();
    static native byte[] inspectPath(byte[] path);
    static native byte[] inspectFd(int fd, long offset);
    static native long loadPath(byte[] path, int nCtx, int nThreads, boolean mmap, Callback cb);
    static native long loadFd(int fd, long offset, int nCtx, int nThreads, boolean mmap, Callback cb);
    static native byte[] modelInfo(long handle);
    static native byte[] generate(long handle, byte[] messagesJson, byte[] paramsJson, Callback cb);
    static native void abort(long handle);
    static native void free(long handle);
}
