package com.syedhuzaif.udppong;

import android.app.NativeActivity;
import android.content.Context;
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
import java.net.URL;
import java.nio.charset.StandardCharsets;

public final class NativeLoader extends NativeActivity {
    private static final int INPUT_TEXT = 0;
    private static final int INPUT_NUMBER = 1;
    private static final int INPUT_URI = 2;
    private static final int INPUT_CODE = 3;

    private EditText textInput;
    private volatile String nativeText = "";

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

    // Called synchronously from the native game thread. The rendezvous protocol
    // uses tiny text bodies, so keeping this bridge deliberately small is fine.
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
