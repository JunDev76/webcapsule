import React, {useCallback, useState} from 'react';
import {
  SafeAreaView,
  StyleSheet,
  Text,
  View,
  TouchableOpacity,
  ScrollView,
} from 'react-native';
import {
  WebCapsuleView,
  installWebCapsuleUpdate,
  getWebCapsuleRuntimeState,
  type WebCapsuleRuntimeState,
} from '@webcapsule/react-native';
import {DEMO_PUBLIC_KEY} from './demo-config';

const CAPSULE_ID = 'dev.webcapsule.demo';
const BUNDLED_ASSET_PATH = 'WebCapsule/bundled-v1.capsule';
const RUNTIME_VERSION = '1.0.0';
const PUBLIC_KEYS = {demo: DEMO_PUBLIC_KEY};
const INDEX_BASE = 'https://jundev76.github.io/webcapsule-demo-tmp/releases';

type LogEntry = {time: string; text: string};

function App(): React.JSX.Element {
  const [status, setStatus] = useState('mounting bundled capsule');
  const [state, setRuntimeState] = useState<WebCapsuleRuntimeState | null>(
    null,
  );
  const [busy, setBusy] = useState(false);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [sessionKey, setSessionKey] = useState(0);

  const log = useCallback((text: string) => {
    const time = new Date().toLocaleTimeString('en-GB', {hour12: false});
    setLogs(prev => [{time, text}, ...prev].slice(0, 12));
  }, []);

  const baseOptions = {
    capsuleId: CAPSULE_ID,
    bundledAssetPath: BUNDLED_ASSET_PATH,
    publicKeys: PUBLIC_KEYS,
    runtimeVersion: RUNTIME_VERSION,
  };

  const refreshState = useCallback(async () => {
    try {
      const s = await getWebCapsuleRuntimeState(baseOptions);
      setRuntimeState(s);
      log(
        `state: active ${s.activeVersion}(${s.activeHealthy ? 'healthy' : 'unhealthy'}) previous ${s.previousVersion ?? '-'} pending ${s.pending?.version ?? '-'} blocked [${s.blockedVersions.join(', ')}]`,
      );
    } catch (e) {
      log(`state error: ${(e as Error).message}`);
    }
  }, [log]);

  const installFrom = useCallback(
    async (indexFile: string, label: string) => {
      setBusy(true);
      setStatus(`installing ${label}...`);
      log(`install ${label}`);
      try {
        const result = await installWebCapsuleUpdate({
          ...baseOptions,
          indexUrl: `${INDEX_BASE}/${indexFile}`,
          channel: 'stable',
        });
        if (result.status === 'installed') {
          log(
            `installed: ${result.previousVersion} -> ${result.currentVersion}`,
          );
          setStatus(
            `pending ${result.currentVersion} (active ${result.previousVersion})`,
          );
        } else {
          log(`up-to-date: ${result.currentVersion}`);
          setStatus(`up-to-date ${result.currentVersion}`);
        }
        await refreshState();
      } catch (e) {
        const message = (e as Error).message;
        log(`install failed: ${message}`);
        setStatus(`install failed: ${message}`);
      } finally {
        setBusy(false);
      }
    },
    [log, refreshState],
  );

  const openNewSession = useCallback(() => {
    setSessionKey(k => k + 1);
    log('new session opened');
    setStatus('new session starting...');
  }, [log]);

  return (
    <SafeAreaView style={styles.screen}>
      <Text style={styles.heading}>WebCapsule demo</Text>
      <Text selectable style={styles.meta}>
        capsuleId: {CAPSULE_ID}
      </Text>
      <Text selectable style={styles.meta}>
        runtimeVersion: {RUNTIME_VERSION}
      </Text>
      <Text selectable style={styles.meta}>
        event: {status}
      </Text>

      <View style={styles.buttons}>
        <TouchableOpacity
          style={[styles.button, busy && styles.buttonDisabled]}
          disabled={busy}
          onPress={() => void installFrom('stable-v2.json', 'v2 (healthy)')}>
          <Text style={styles.buttonText}>v2 update install</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.button, busy && styles.buttonDisabled]}
          disabled={busy}
          onPress={() => void installFrom('stable-v3.json', 'v3 (broken)')}>
          <Text style={styles.buttonText}>v3 update install</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={styles.button}
          onPress={() => void refreshState()}>
          <Text style={styles.buttonText}>refresh state</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.button} onPress={openNewSession}>
          <Text style={styles.buttonText}>open new session</Text>
        </TouchableOpacity>
      </View>

      <View style={styles.stateBox}>
        <Text style={styles.stateHeading}>runtime state</Text>
        <Text selectable style={styles.stateText}>
          {state
            ? `active: ${state.activeVersion} (${state.activeHealthy ? 'healthy' : 'unhealthy'})\nprevious: ${state.previousVersion ?? '-'}\npending: ${state.pending ? `${state.pending.version} (attempts ${state.pending.attempts})` : '-'}\nblocked: [${state.blockedVersions.join(', ')}]\ngeneration: ${state.generation}`
            : '(press refresh state)'}
        </Text>
      </View>

      <View style={styles.capsule}>
        <WebCapsuleView
          key={sessionKey}
          style={styles.capsule}
          capsuleId={CAPSULE_ID}
          bundledAssetPath={BUNDLED_ASSET_PATH}
          publicKeys={PUBLIC_KEYS}
          runtimeVersion={RUNTIME_VERSION}
          onLoad={({nativeEvent}) => {
            setStatus(`healthy ${nativeEvent.version}`);
            log(`load: healthy ${nativeEvent.version}`);
          }}
          onError={({nativeEvent}) => {
            setStatus(`error ${nativeEvent.code}`);
            log(`error: ${nativeEvent.code} ${nativeEvent.message}`);
          }}
          onRollback={({nativeEvent}) => {
            setStatus(
              `rollback ${nativeEvent.failedVersion} -> ${nativeEvent.restoredVersion ?? 'bundled'}`,
            );
            log(
              `rollback: ${nativeEvent.failedVersion} -> ${nativeEvent.restoredVersion ?? 'bundled'}`,
            );
          }}
        />
      </View>

      <View style={styles.logBox}>
        <Text style={styles.stateHeading}>event log</Text>
        <ScrollView style={styles.logScroll}>
          {logs.map((entry, i) => (
            <Text key={i} selectable style={styles.logText}>
              {entry.time} {entry.text}
            </Text>
          ))}
        </ScrollView>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1, padding: 12, gap: 4, backgroundColor: '#fff'},
  heading: {fontSize: 17, fontWeight: '700', marginBottom: 2},
  meta: {fontSize: 11, color: '#333'},
  buttons: {flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginVertical: 6},
  button: {
    backgroundColor: '#2563eb',
    paddingHorizontal: 10,
    paddingVertical: 7,
    borderRadius: 6,
  },
  buttonDisabled: {backgroundColor: '#9ca3af'},
  buttonText: {color: '#fff', fontSize: 12, fontWeight: '600'},
  stateBox: {
    borderWidth: 1,
    borderColor: '#ccc',
    padding: 6,
    borderRadius: 4,
    marginBottom: 4,
  },
  stateHeading: {fontSize: 11, fontWeight: '700', marginBottom: 2},
  stateText: {fontSize: 11, color: '#333', fontFamily: 'Menlo'},
  capsule: {flex: 1, borderWidth: 1, borderColor: '#888', minHeight: 120},
  logBox: {
    height: 90,
    borderWidth: 1,
    borderColor: '#ccc',
    borderRadius: 4,
    marginTop: 4,
    padding: 4,
  },
  logScroll: {flex: 1},
  logText: {fontSize: 10, color: '#555', fontFamily: 'Menlo'},
});

export default App;
