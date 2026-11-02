/*
   INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
   NO LICENCE IS GRANTED. See LICENCE.txt.

   JNI bridge between NativeEngine.java and the shared engine (native/).
   Text crosses as UTF-8 byte arrays rather than Java strings: JNI's own string
   conversion uses "modified UTF-8", which would mangle emoji and other
   characters outside the basic plane.
*/
#include <jni.h>

#include <android/log.h>
#include <unistd.h>

#include <cstring>
#include <string>

#include "ingenium_engine.h"

namespace {

const char * TAG = "IngeniumEngine";

void log_cb(int level, const char * text) {
    int prio = level >= 4 ? ANDROID_LOG_ERROR : (level == 3 ? ANDROID_LOG_WARN : ANDROID_LOG_INFO);
    __android_log_write(prio, TAG, text);
}

void throw_rt(JNIEnv * env, const std::string & msg) {
    jclass c = env->FindClass("java/lang/RuntimeException");
    if (c) {
        env->ThrowNew(c, msg.c_str());
    }
}

jbyteArray to_bytes(JNIEnv * env, const char * p, size_t n) {
    jbyteArray a = env->NewByteArray((jsize) n);
    if (a && n) {
        env->SetByteArrayRegion(a, 0, (jsize) n, (const jbyte *) p);
    }
    return a;
}

jbyteArray take_str(JNIEnv * env, char * s) {
    if (!s) {
        return nullptr;
    }
    jbyteArray a = to_bytes(env, s, strlen(s));
    ie_free_str(s);
    return a;
}

std::string from_bytes(JNIEnv * env, jbyteArray a) {
    if (!a) {
        return {};
    }
    jsize       n = env->GetArrayLength(a);
    std::string s((size_t) n, '\0');
    if (n) {
        env->GetByteArrayRegion(a, 0, n, (jbyte *) &s[0]);
    }
    return s;
}

struct callbacks {
    JNIEnv *  env;
    jobject   cb;
    jmethodID on_piece;
    jmethodID on_progress;
};

callbacks make_callbacks(JNIEnv * env, jobject cb) {
    callbacks c{ env, cb, nullptr, nullptr };
    if (cb) {
        jclass k      = env->GetObjectClass(cb);
        c.on_piece    = env->GetMethodID(k, "onPiece", "(I[B)V");
        c.on_progress = env->GetMethodID(k, "onProgress", "(F)Z");
        env->DeleteLocalRef(k);
    }
    return c;
}

void piece_tramp(void * user, int kind, const char * text, size_t len) {
    auto * c = (callbacks *) user;
    if (!c->cb || !c->on_piece) {
        return;
    }
    jbyteArray b = to_bytes(c->env, text, len);
    c->env->CallVoidMethod(c->cb, c->on_piece, (jint) kind, b);
    c->env->DeleteLocalRef(b);
    if (c->env->ExceptionCheck()) {
        c->env->ExceptionClear();
    }
}

bool progress_tramp(void * user, float p) {
    auto * c = (callbacks *) user;
    if (!c->cb || !c->on_progress) {
        return true;
    }
    jboolean go = c->env->CallBooleanMethod(c->cb, c->on_progress, (jfloat) p);
    if (c->env->ExceptionCheck()) {
        c->env->ExceptionClear();
        return true;
    }
    return go == JNI_TRUE;
}

// A model and the file it was read from (kept open while the model lives).
struct handle {
    ie_model * m;
    FILE *     fp;
};

FILE * open_at(int fd, jlong offset) {
    int dup_fd = dup(fd);
    if (dup_fd < 0) {
        return nullptr;
    }
    FILE * fp = fdopen(dup_fd, "rb");
    if (!fp) {
        close(dup_fd);
        return nullptr;
    }
    if (fseeko(fp, (off_t) offset, SEEK_SET) != 0) {
        fclose(fp);
        return nullptr;
    }
    return fp;
}

jlong finish_load(JNIEnv * env, ie_model * m, FILE * fp, const char * err) {
    if (!m) {
        if (fp) {
            fclose(fp);
        }
        throw_rt(env, err && *err ? err : "The model could not be loaded.");
        return 0;
    }
    return (jlong) (intptr_t) new handle{ m, fp };
}

}  // namespace

extern "C" {

JNIEXPORT void JNICALL Java_com_yannieforest_ingenium_NativeEngine_init(JNIEnv *, jclass) {
    ie_backend_init(log_cb);
}

JNIEXPORT jstring JNICALL Java_com_yannieforest_ingenium_NativeEngine_version(JNIEnv * env, jclass) {
    return env->NewStringUTF(ie_version());
}

JNIEXPORT jbyteArray JNICALL Java_com_yannieforest_ingenium_NativeEngine_inspectPath(JNIEnv * env, jclass,
                                                                                     jbyteArray path) {
    std::string p = from_bytes(env, path);
    return take_str(env, ie_inspect(p.c_str(), nullptr));
}

JNIEXPORT jbyteArray JNICALL Java_com_yannieforest_ingenium_NativeEngine_inspectFd(JNIEnv * env, jclass, jint fd,
                                                                                   jlong offset) {
    FILE * fp = open_at(fd, offset);
    if (!fp) {
        return nullptr;
    }
    jbyteArray out = take_str(env, ie_inspect(nullptr, fp));
    fclose(fp);
    return out;
}

JNIEXPORT jlong JNICALL Java_com_yannieforest_ingenium_NativeEngine_loadPath(JNIEnv * env, jclass, jbyteArray path,
                                                                             jint n_ctx, jint n_threads,
                                                                             jboolean mmap, jobject cb) {
    std::string    p = from_bytes(env, path);
    callbacks      c = make_callbacks(env, cb);
    ie_load_params lp{ n_ctx, n_threads, 0, mmap == JNI_TRUE };
    char           err[512] = { 0 };
    ie_model *     m        = ie_load(p.c_str(), nullptr, &lp, progress_tramp, &c, err, sizeof(err));
    return finish_load(env, m, nullptr, err);
}

JNIEXPORT jlong JNICALL Java_com_yannieforest_ingenium_NativeEngine_loadFd(JNIEnv * env, jclass, jint fd,
                                                                           jlong offset, jint n_ctx, jint n_threads,
                                                                           jboolean mmap, jobject cb) {
    FILE * fp = open_at(fd, offset);
    if (!fp) {
        throw_rt(env, "The model inside the app could not be opened.");
        return 0;
    }
    callbacks      c = make_callbacks(env, cb);
    ie_load_params lp{ n_ctx, n_threads, 0, mmap == JNI_TRUE };
    char           err[512] = { 0 };
    ie_model *     m        = ie_load(nullptr, fp, &lp, progress_tramp, &c, err, sizeof(err));
    return finish_load(env, m, fp, err);
}

JNIEXPORT jbyteArray JNICALL Java_com_yannieforest_ingenium_NativeEngine_modelInfo(JNIEnv * env, jclass, jlong h) {
    auto * hd = (handle *) (intptr_t) h;
    return hd ? take_str(env, ie_model_info(hd->m)) : nullptr;
}

JNIEXPORT jbyteArray JNICALL Java_com_yannieforest_ingenium_NativeEngine_generate(JNIEnv * env, jclass, jlong h,
                                                                                  jbyteArray messages,
                                                                                  jbyteArray params, jobject cb) {
    auto * hd = (handle *) (intptr_t) h;
    if (!hd) {
        throw_rt(env, "No model is loaded.");
        return nullptr;
    }
    std::string msgs = from_bytes(env, messages);
    std::string prm  = from_bytes(env, params);
    callbacks   c    = make_callbacks(env, cb);
    char        err[512] = { 0 };
    char *      stats    = ie_generate(hd->m, msgs.c_str(), prm.c_str(), piece_tramp, &c, err, sizeof(err));
    if (!stats) {
        throw_rt(env, err[0] ? err : "The engine could not answer.");
        return nullptr;
    }
    return take_str(env, stats);
}

JNIEXPORT void JNICALL Java_com_yannieforest_ingenium_NativeEngine_abort(JNIEnv *, jclass, jlong h) {
    auto * hd = (handle *) (intptr_t) h;
    if (hd) {
        ie_abort(hd->m);
    }
}

JNIEXPORT void JNICALL Java_com_yannieforest_ingenium_NativeEngine_free(JNIEnv *, jclass, jlong h) {
    auto * hd = (handle *) (intptr_t) h;
    if (!hd) {
        return;
    }
    ie_free(hd->m);
    if (hd->fp) {
        fclose(hd->fp);
    }
    delete hd;
}

}  // extern "C"
