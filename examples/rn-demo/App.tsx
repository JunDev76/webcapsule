import React, {useState} from 'react';
import {SafeAreaView, StyleSheet, Text, View} from 'react-native';
import {WebCapsuleView} from '@webcapsule/react-native';
import {DEMO_PUBLIC_KEY} from './demo-config';

const CAPSULE_ID = 'dev.webcapsule.demo';

function App(): React.JSX.Element {
  const [status, setStatus] = useState('mounting bundled capsule');

  return (
    <SafeAreaView style={styles.screen}>
      <Text style={styles.heading}>WebCapsule iOS debug demo</Text>
      <Text selectable>capsuleId: {CAPSULE_ID}</Text>
      <Text selectable>runtimeVersion: 1.0.0</Text>
      <Text selectable>event: {status}</Text>
      <View style={styles.capsule}>
        <WebCapsuleView
          style={styles.capsule}
          capsuleId={CAPSULE_ID}
          bundledAssetPath="WebCapsule/bundled-v1.capsule"
          publicKeys={{demo: DEMO_PUBLIC_KEY}}
          runtimeVersion="1.0.0"
          onLoad={({nativeEvent}) =>
            setStatus(`healthy ${nativeEvent.version}`)
          }
          onError={({nativeEvent}) =>
            setStatus(`error ${nativeEvent.code}: ${nativeEvent.message}`)
          }
          onRollback={({nativeEvent}) =>
            setStatus(
              `rollback ${nativeEvent.failedVersion} -> ${nativeEvent.restoredVersion ?? 'bundled'}`,
            )
          }
        />
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1, padding: 16, gap: 4},
  heading: {fontSize: 18, fontWeight: '600', marginBottom: 4},
  capsule: {flex: 1, marginTop: 8, borderWidth: 1, borderColor: '#888'},
});

export default App;
