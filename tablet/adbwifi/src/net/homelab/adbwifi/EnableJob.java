package net.homelab.adbwifi;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.provider.Settings;
import android.util.Log;

/** Turns Wireless debugging on (Settings.Global adb_wifi_enabled = 1).
 *
 * Android resets the setting to 0 at every boot and whenever Wi-Fi drops, and
 * refuses it while Wi-Fi is down: both jobs wait for an unmetered network.
 * The boot job retries (backoff) until the setting holds; the periodic one
 * catches a Wi-Fi reconnection. Turning it on only works without a tap on a
 * network that was "always allowed" once by hand. */
public class EnableJob extends JobService {
    static final String TAG = "adbwifi";
    static final String KEY = "adb_wifi_enabled";
    static final int BOOT_JOB = 1;
    static final int PERIODIC_JOB = 2;

    static void schedule(Context ctx) {
        JobScheduler js = ctx.getSystemService(JobScheduler.class);
        ComponentName cn = new ComponentName(ctx, EnableJob.class);
        js.schedule(new JobInfo.Builder(BOOT_JOB, cn)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED)
                .setMinimumLatency(3000)
                .setBackoffCriteria(10000, JobInfo.BACKOFF_POLICY_LINEAR)
                .build());
        js.schedule(new JobInfo.Builder(PERIODIC_JOB, cn)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED)
                .setPeriodic(15 * 60 * 1000L)
                .setPersisted(true)
                .build());
    }

    static boolean enabled(Context ctx) {
        return Settings.Global.getInt(ctx.getContentResolver(), KEY, 0) == 1;
    }

    @Override
    public boolean onStartJob(final JobParameters params) {
        if (enabled(this)) {
            Log.i(TAG, "job " + params.getJobId() + ": already on");
            return false;
        }
        try {
            Settings.Global.putInt(getContentResolver(), KEY, 1);
        } catch (SecurityException e) {
            Log.e(TAG, "WRITE_SECURE_SETTINGS not granted: " + e.getMessage());
            return false;
        }
        // Android may switch it back off at once (Wi-Fi not ready, untrusted
        // network): read it again a little later and retry if so.
        new Thread(new Runnable() {
            public void run() {
                try { Thread.sleep(5000); } catch (InterruptedException e) { }
                boolean on = enabled(EnableJob.this);
                Log.i(TAG, "job " + params.getJobId() + ": set to 1, " + (on ? "holds" : "reset, retrying"));
                jobFinished(params, !on);
            }
        }).start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        return true;
    }
}
