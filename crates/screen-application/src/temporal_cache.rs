//! Bounded in-memory cache for exact immutable temporal artifacts.
//!
//! Cache state is never authored simulation state. A miss or eviction recomputes the same typed
//! artifact; no nearby time, raster, phase or parameter identity may substitute for the exact key.

use std::collections::HashMap;
use std::hash::Hash;
use std::sync::{Arc, Condvar, Mutex};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TemporalCacheConfiguration {
    maximum_bytes: u64,
}

impl TemporalCacheConfiguration {
    pub const fn new(maximum_bytes: u64) -> Self {
        Self { maximum_bytes }
    }

    pub const fn maximum_bytes(self) -> u64 {
        self.maximum_bytes
    }
}

#[derive(Clone, Debug)]
pub struct CacheArtifact<V> {
    pub value: V,
    pub resident_bytes: u64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TemporalCacheStats {
    pub hits: u64,
    pub misses: u64,
    pub waits: u64,
    pub evictions: u64,
    pub resident_bytes: u64,
    pub entries: usize,
}

struct ReadyEntry<V> {
    value: Arc<V>,
    resident_bytes: u64,
    access: u64,
}

struct InFlight<V, E> {
    result: Mutex<Option<Result<Arc<V>, E>>>,
    ready: Condvar,
}

impl<V, E> InFlight<V, E> {
    fn new() -> Self {
        Self {
            result: Mutex::new(None),
            ready: Condvar::new(),
        }
    }
}

struct CacheState<K, V, E> {
    configuration: TemporalCacheConfiguration,
    ready: HashMap<K, ReadyEntry<V>>,
    in_flight: HashMap<K, Arc<InFlight<V, E>>>,
    access: u64,
    stats: TemporalCacheStats,
}

/// Thread-safe exact cache with single-flight evaluation for identical keys.
pub struct TemporalArtifactCache<K, V, E> {
    state: Mutex<CacheState<K, V, E>>,
}

impl<K, V, E> TemporalArtifactCache<K, V, E>
where
    K: Clone + Eq + Hash,
    E: Clone,
{
    pub fn new(configuration: TemporalCacheConfiguration) -> Self {
        Self {
            state: Mutex::new(CacheState {
                configuration,
                ready: HashMap::new(),
                in_flight: HashMap::new(),
                access: 0,
                stats: TemporalCacheStats::default(),
            }),
        }
    }

    pub fn configuration(&self) -> TemporalCacheConfiguration {
        self.state
            .lock()
            .expect("temporal cache poisoned")
            .configuration
    }

    pub fn set_configuration(&self, configuration: TemporalCacheConfiguration) {
        let mut state = self.state.lock().expect("temporal cache poisoned");
        state.configuration = configuration;
        evict_to_limit(&mut state);
    }

    pub fn clear(&self) {
        let mut state = self.state.lock().expect("temporal cache poisoned");
        state.ready.clear();
        state.stats.resident_bytes = 0;
        state.stats.entries = 0;
    }

    pub fn stats(&self) -> TemporalCacheStats {
        self.state.lock().expect("temporal cache poisoned").stats
    }

    pub fn get_or_try_insert_with<F>(&self, key: K, compute: F) -> Result<Arc<V>, E>
    where
        F: FnOnce() -> Result<CacheArtifact<V>, E>,
    {
        let (flight, owns_flight) = {
            let mut state = self.state.lock().expect("temporal cache poisoned");
            state.access = state.access.wrapping_add(1);
            let access = state.access;
            if let Some(entry) = state.ready.get_mut(&key) {
                entry.access = access;
                let value = Arc::clone(&entry.value);
                state.stats.hits = state.stats.hits.wrapping_add(1);
                return Ok(value);
            }
            if let Some(flight) = state.in_flight.get(&key) {
                let flight = Arc::clone(flight);
                state.stats.waits = state.stats.waits.wrapping_add(1);
                (flight, false)
            } else {
                let flight = Arc::new(InFlight::new());
                state.in_flight.insert(key.clone(), Arc::clone(&flight));
                state.stats.misses = state.stats.misses.wrapping_add(1);
                (flight, true)
            }
        };

        if !owns_flight {
            let mut result = flight
                .result
                .lock()
                .expect("temporal cache flight poisoned");
            while result.is_none() {
                result = flight
                    .ready
                    .wait(result)
                    .expect("temporal cache flight poisoned");
            }
            return result.as_ref().expect("flight result present").clone();
        }

        let computed = compute().map(|artifact| {
            let value = Arc::new(artifact.value);
            (value, artifact.resident_bytes)
        });

        let published = match &computed {
            Ok((value, _)) => Ok(Arc::clone(value)),
            Err(error) => Err(error.clone()),
        };
        {
            let mut result = flight
                .result
                .lock()
                .expect("temporal cache flight poisoned");
            *result = Some(published.clone());
            flight.ready.notify_all();
        }

        let mut state = self.state.lock().expect("temporal cache poisoned");
        state.in_flight.remove(&key);
        if let Ok((value, resident_bytes)) = computed {
            let maximum = state.configuration.maximum_bytes();
            if resident_bytes <= maximum && maximum != 0 {
                while state.stats.resident_bytes.saturating_add(resident_bytes) > maximum {
                    if !evict_one(&mut state) {
                        break;
                    }
                }
                state.access = state.access.wrapping_add(1);
                let access = state.access;
                state.ready.insert(
                    key,
                    ReadyEntry {
                        value,
                        resident_bytes,
                        access,
                    },
                );
                state.stats.resident_bytes =
                    state.stats.resident_bytes.saturating_add(resident_bytes);
                state.stats.entries = state.ready.len();
            }
        }
        published
    }
}

fn evict_to_limit<K, V, E>(state: &mut CacheState<K, V, E>)
where
    K: Clone + Eq + Hash,
{
    while state.stats.resident_bytes > state.configuration.maximum_bytes() {
        if !evict_one(state) {
            break;
        }
    }
}

fn evict_one<K, V, E>(state: &mut CacheState<K, V, E>) -> bool
where
    K: Clone + Eq + Hash,
{
    let Some(key) = state
        .ready
        .iter()
        .min_by_key(|(_, entry)| entry.access)
        .map(|(key, _)| key.clone())
    else {
        return false;
    };
    let entry = state
        .ready
        .remove(&key)
        .expect("selected cache entry exists");
    state.stats.resident_bytes = state
        .stats
        .resident_bytes
        .saturating_sub(entry.resident_bytes);
    state.stats.entries = state.ready.len();
    state.stats.evictions = state.stats.evictions.wrapping_add(1);
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread;

    #[test]
    fn exact_hit_reuses_the_same_immutable_artifact() {
        let cache =
            TemporalArtifactCache::<u64, Vec<u8>, ()>::new(TemporalCacheConfiguration::new(1024));
        let calls = AtomicUsize::new(0);
        let first = cache
            .get_or_try_insert_with(7, || {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(CacheArtifact {
                    value: vec![1, 2, 3],
                    resident_bytes: 3,
                })
            })
            .unwrap();
        let second = cache
            .get_or_try_insert_with(7, || {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(CacheArtifact {
                    value: vec![9],
                    resident_bytes: 1,
                })
            })
            .unwrap();
        assert!(Arc::ptr_eq(&first, &second));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(cache.stats().hits, 1);
    }

    #[test]
    fn byte_limit_evicts_the_least_recently_used_entry() {
        let cache = TemporalArtifactCache::<u64, u64, ()>::new(TemporalCacheConfiguration::new(16));
        for key in [1, 2] {
            cache
                .get_or_try_insert_with(key, || {
                    Ok(CacheArtifact {
                        value: key,
                        resident_bytes: 8,
                    })
                })
                .unwrap();
        }
        cache.get_or_try_insert_with(1, || unreachable!()).unwrap();
        cache
            .get_or_try_insert_with(3, || {
                Ok(CacheArtifact {
                    value: 3,
                    resident_bytes: 8,
                })
            })
            .unwrap();
        let calls = AtomicUsize::new(0);
        cache
            .get_or_try_insert_with(2, || {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(CacheArtifact {
                    value: 2,
                    resident_bytes: 8,
                })
            })
            .unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(cache.stats().evictions >= 1);
    }

    #[test]
    fn concurrent_identical_requests_compute_once() {
        let cache = Arc::new(TemporalArtifactCache::<u64, u64, ()>::new(
            TemporalCacheConfiguration::new(1024),
        ));
        let calls = Arc::new(AtomicUsize::new(0));
        let threads = (0..8)
            .map(|_| {
                let cache = Arc::clone(&cache);
                let calls = Arc::clone(&calls);
                thread::spawn(move || {
                    cache
                        .get_or_try_insert_with(42, || {
                            calls.fetch_add(1, Ordering::SeqCst);
                            thread::sleep(std::time::Duration::from_millis(10));
                            Ok(CacheArtifact {
                                value: 42,
                                resident_bytes: 8,
                            })
                        })
                        .unwrap()
                })
            })
            .collect::<Vec<_>>();
        let values = threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(
            values
                .windows(2)
                .all(|pair| Arc::ptr_eq(&pair[0], &pair[1]))
        );
        assert_eq!(cache.stats().waits, 7);
    }

    #[test]
    fn zero_capacity_shares_in_flight_but_retains_nothing() {
        let cache = TemporalArtifactCache::<u64, u64, ()>::new(TemporalCacheConfiguration::new(0));
        cache
            .get_or_try_insert_with(1, || {
                Ok(CacheArtifact {
                    value: 1,
                    resident_bytes: 8,
                })
            })
            .unwrap();
        assert_eq!(cache.stats().entries, 0);
        assert_eq!(cache.stats().resident_bytes, 0);
    }
}
