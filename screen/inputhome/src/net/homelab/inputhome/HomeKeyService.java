package net.homelab.inputhome;

import android.accessibilityservice.AccessibilityService;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.KeyEvent;
import android.view.ViewConfiguration;
import android.view.accessibility.AccessibilityEvent;

/**
 * Home key: a short press opens the TV input, a long press the stock home screen.
 * It also opens the TV input on every wake from standby, and once right after boot,
 * since boot lands on the stock home.
 */
public class HomeKeyService extends AccessibilityService {
    /** The system binds the service within this long of boot; a later bind is a restart. */
    private static final long BOOT_WINDOW_MS = 5 * 60 * 1000;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable longPress = new Runnable() {
        @Override
        public void run() {
            longPressed = true;
            startActivity(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        }
    };
    private boolean longPressed;

    private final BroadcastReceiver screenOn = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            openTv();
        }
    };

    @Override
    protected void onServiceConnected() {
        registerReceiver(screenOn, new IntentFilter(Intent.ACTION_SCREEN_ON));
        if (SystemClock.elapsedRealtime() < BOOT_WINDOW_MS) openTv();
    }

    @Override
    public void onDestroy() {
        unregisterReceiver(screenOn);
        super.onDestroy();
    }

    @Override
    protected boolean onKeyEvent(KeyEvent event) {
        if (event.getKeyCode() != KeyEvent.KEYCODE_HOME) return false;
        if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
            longPressed = false;
            handler.postDelayed(longPress, ViewConfiguration.getLongPressTimeout());
        } else if (event.getAction() == KeyEvent.ACTION_UP) {
            handler.removeCallbacks(longPress);
            if (!longPressed) openTv();
        }
        return true;
    }

    private void openTv() {
        startActivity(new Intent(this, TvActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {}

    @Override
    public void onInterrupt() {}
}
