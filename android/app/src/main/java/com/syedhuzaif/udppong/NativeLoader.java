package com.syedhuzaif.udppong;

import android.app.NativeActivity;
import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;
import android.os.Bundle;
import android.text.Editable;
import android.text.InputFilter;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public final class NativeLoader extends NativeActivity {
    private static final int INPUT_TEXT = 0;
    private static final int INPUT_NUMBER = 1;
    private static final int INPUT_URI = 2;
    private static final int INPUT_CODE = 3;

    private EditText textInput;
    private volatile String nativeText = "";

    private static final String PREFS_NAME = "udp_pong";
    private static final String PREFS_CONFIG_KEY = "pong_cfg";
    private static final String PREFS_LOG_TAG = "UDPPongPrefs";

    private static final int ASYNC_IDLE = 0;
    private static final int ASYNC_RUNNING = 1;
    private static final int ASYNC_SUCCESS = 2;
    private static final int ASYNC_FAILED = 3;

    // Only one rendezvous/DNS job is needed at a time. The native Internet_State
    // already serializes create/join/wait operations. generation prevents a late
    // result from an abandoned request from contaminating a newer room attempt.
    private final Object asyncLock = new Object();
    private int asyncGeneration = 0;
    private volatile int asyncState = ASYNC_IDLE;
    private volatile String asyncResult = null;

    static {
        System.loadLibrary("main");
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);

        // Keep raylib's surface at the physical screen size while the IME overlays it.
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING);

        textInput = new EditText(this);
        textInput.setSingleLine(true);
        textInput.setBackgroundColor(0x00000000);
        textInput.setTextColor(0x00000000);
        textInput.setCursorVisible(false);
        textInput.setPadding(0, 0, 0, 0);
        textInput.setFilters(new InputFilter[] { new InputFilter.LengthFilter(160) });
        textInput.setImeOptions(EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_ACTION_DONE);

        // A real EditText/InputConnection is required for Android IMEs to commit text.
        // It stays effectively invisible; Pong renders its own text fields in raylib.
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(2, 2);
        params.leftMargin = 0;
        params.topMargin = 0;
        addContentView(textInput, params);

        textInput.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {}
            @Override public void afterTextChanged(Editable s) {
                nativeText = s.toString();
            }
        });
    }

    private int androidInputType(int kind) {
        switch (kind) {
            case INPUT_NUMBER:
                return InputType.TYPE_CLASS_NUMBER;
            case INPUT_URI:
                return InputType.TYPE_CLASS_TEXT |
                       InputType.TYPE_TEXT_VARIATION_URI |
                       InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            case INPUT_CODE:
                return InputType.TYPE_CLASS_TEXT |
                       InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS |
                       InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            case INPUT_TEXT:
            default:
                return InputType.TYPE_CLASS_TEXT |
                       InputType.TYPE_TEXT_FLAG_CAP_WORDS;
        }
    }

    // Called from the native game thread. UI work is posted to Android's UI thread;
    // nativeText is updated immediately so the next game frame still sees the old/current
    // field value until EditText has been initialized.
    public void beginTextInput(final String initial, final int kind) {
        nativeText = initial != null ? initial : "";
        runOnUiThread(() -> {
            if (textInput == null) return;

            textInput.setInputType(androidInputType(kind));
            textInput.setImeOptions(EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_ACTION_DONE);
            textInput.setSingleLine(true);
            textInput.setText(nativeText);
            textInput.setSelection(textInput.length());
            textInput.requestFocus();

            InputMethodManager imm = (InputMethodManager)getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) {
                imm.restartInput(textInput);
                textInput.post(() -> imm.showSoftInput(textInput, InputMethodManager.SHOW_IMPLICIT));
            }
        });
    }

    public void endTextInput() {
        runOnUiThread(() -> {
            if (textInput == null) return;
            InputMethodManager imm = (InputMethodManager)getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.hideSoftInputFromWindow(textInput.getWindowToken(), 0);
            textInput.clearFocus();
            View decor = getWindow().getDecorView();
            decor.setFocusableInTouchMode(true);
            decor.requestFocus();
        });
    }

    // Safe to call from the native game thread: only returns the volatile mirror,
    // never touches the EditText object off the UI thread.
    public String getTextInput() {
        return nativeText;
    }

    // Android preferences use the platform's private persistent storage instead of
    // relying on Odin core:os file I/O. The payload remains the same pong.cfg text
    // used by desktop, so parsing/formatting stays shared in Odin.
    public String loadConfigText() {
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        String text = prefs.getString(PREFS_CONFIG_KEY, "");
        if (text == null) text = "";
        Log.i(PREFS_LOG_TAG, "load bytes=" + text.getBytes(StandardCharsets.UTF_8).length);
        return text;
    }

    public boolean saveConfigText(String text) {
        if (text == null) text = "";
        boolean ok = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(PREFS_CONFIG_KEY, text)
            .commit();
        Log.i(PREFS_LOG_TAG, "save bytes=" + text.getBytes(StandardCharsets.UTF_8).length + " ok=" + ok);
        return ok;
    }

    private void publishAsyncResult(int generation, String result) {
        synchronized (asyncLock) {
            if (generation != asyncGeneration || asyncState != ASYNC_RUNNING) return;
            asyncResult = result;
            asyncState = (result != null && !result.isEmpty()) ? ASYNC_SUCCESS : ASYNC_FAILED;
        }
    }

    public boolean beginAsyncResolve(final String host) {
        if (host == null || host.isEmpty()) return false;

        final int generation;
        synchronized (asyncLock) {
            if (asyncState == ASYNC_RUNNING) return false;
            generation = ++asyncGeneration;
            asyncResult = null;
            asyncState = ASYNC_RUNNING;
        }

        Thread worker = new Thread(() -> {
            String result = null;
            try {
                InetAddress[] addresses = InetAddress.getAllByName(host);
                InetAddress chosen = null;

                // The Pong STUN parser currently consumes IPv4 XOR-MAPPED-ADDRESS.
                // Prefer an IPv4 Cloudflare endpoint just like the desktop path.
                for (InetAddress address : addresses) {
                    if (address instanceof Inet4Address) {
                        chosen = address;
                        break;
                    }
                }
                if (chosen == null && addresses.length > 0) chosen = addresses[0];
                if (chosen != null) result = chosen.getHostAddress();
            } catch (Exception ignored) {
            }
            publishAsyncResult(generation, result);
        }, "Pong-STUN-DNS");
        worker.setDaemon(true);
        worker.start();
        return true;
    }

    public boolean beginAsyncHttpPost(final String url, final String payload, final int timeoutMs) {
        if (url == null || url.isEmpty() || payload == null) return false;

        final int generation;
        synchronized (asyncLock) {
            if (asyncState == ASYNC_RUNNING) return false;
            generation = ++asyncGeneration;
            asyncResult = null;
            asyncState = ASYNC_RUNNING;
        }

        Thread worker = new Thread(() ->
            publishAsyncResult(generation, httpPost(url, payload, timeoutMs)),
            "Pong-Rendezvous-HTTP"
        );
        worker.setDaemon(true);
        worker.start();
        return true;
    }

    public int getAsyncState() {
        return asyncState;
    }

    public String takeAsyncResult() {
        synchronized (asyncLock) {
            if (asyncState != ASYNC_SUCCESS) return null;
            String result = asyncResult;
            asyncResult = null;
            asyncState = ASYNC_IDLE;
            return result;
        }
    }

    public void abandonAsync() {
        synchronized (asyncLock) {
            ++asyncGeneration;
            asyncResult = null;
            asyncState = ASYNC_IDLE;
        }
    }

    // Called by the Java worker thread. The rendezvous protocol uses tiny text
    // bodies, so keeping this bridge deliberately small is fine.
    public String httpPost(String urlText, String payload, int timeoutMs) {
        HttpURLConnection connection = null;
        try {
            URL url = new URL(urlText);
            connection = (HttpURLConnection)url.openConnection();
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setConnectTimeout(Math.min(timeoutMs, 4000));
            connection.setReadTimeout(timeoutMs);
            connection.setInstanceFollowRedirects(true);
            connection.setRequestProperty("Content-Type", "text/plain; charset=utf-8");
            connection.setRequestProperty("User-Agent", "UDP-Pong/1.3.0 Android");

            byte[] body = payload.getBytes(StandardCharsets.UTF_8);
            connection.setFixedLengthStreamingMode(body.length);
            try (OutputStream out = connection.getOutputStream()) {
                out.write(body);
            }

            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) return null;

            InputStream stream = connection.getInputStream();
            StringBuilder response = new StringBuilder(256);
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
                char[] buffer = new char[512];
                int n;
                while ((n = reader.read(buffer)) >= 0) {
                    response.append(buffer, 0, n);
                    if (response.length() > 2048) return null;
                }
            }
            return response.toString();
        } catch (Exception ignored) {
            return null;
        } finally {
            if (connection != null) connection.disconnect();
        }
    }
}
