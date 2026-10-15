> The runnable starter now uses Room 3.0.3 with AndroidSQLiteDriver and includes
> Baseline Profile and Macrobenchmark examples in `:benchmark`. For the current
> build and commands, see [README](README.md) and [Performance testing](docs/PERFORMANCE_TESTING.md).
> The runnable starter uses Preferences DataStore, a fake network boundary, one-time Room seeding, and a preferences dialog. Retrofit and Proto DataStore examples below are optional product extensions, not installed components.

# Modern Android Development Guide
## Based on Now in Android Reference Architecture

Architecture examples reviewed September 19, 2026; runnable-starter and CI notes updated October 10, 2026. Use the [repository version catalog](gradle/libs.versions.toml) and [October refresh notes](docs/OCTOBER_2026_REFRESH.md) for the verified toolchain. NiA examples below illustrate optional patterns; its full module graph is not a prerequisite for a new product.

A comprehensive guide for building production-ready Android applications using Jetpack Compose, following Google's official architecture guidance.

> **Guide versus repository:** This document explains both implemented patterns and optional production architecture. It is not a feature inventory. The authoritative list of code that ships in this starter, including deliberate extension points, is maintained in [README.md](README.md).

---

## Table of Contents

| Chapter | Title | Description |
|---------|-------|-------------|
| 1 | [Introduction](#1-introduction) | Overview of Now in Android as Google's reference architecture for modern Android development |
| 2 | [Module Architecture](#2-module-architecture) | Multi-module setup with 35+ modules organized into core, feature, and sync layers |
| 3 | [Layer Architecture](#3-layer-architecture) | Data, Domain, and UI layers with unidirectional data flow patterns |
| 4 | [Dependency Injection](#4-dependency-injection) | Hilt setup, module organization, scopes, and testing patterns |
| 5 | [Compose UI Fundamentals](#5-compose-ui-fundamentals) | Component design, state hoisting, recomposition optimization |
| 6 | [Design System](#6-design-system) | Material 3 theming, custom components, typography, and color systems |
| 7 | [State Management](#7-state-management) | ViewModel + StateFlow + sealed UI state patterns for reactive UIs |
| 8 | [Navigation](#8-navigation) | Navigation3, multi-level back stacks, type-safe navigation keys |
| 9 | [Data Layer](#9-data-layer) | Repository pattern, Room database, Proto DataStore implementation |
| 10 | [Network Layer](#10-network-layer) | Retrofit setup, network models, flavor-based implementations |
| 11 | [Offline-First Architecture](#11-offline-first-architecture) | Local-first reads, sync strategies, change list algorithm |
| 12 | [Background Sync](#12-background-sync) | WorkManager integration, Synchronizer pattern, retry strategies |
| 13 | [Domain Use Cases](#13-domain-use-cases) | When and how to implement the domain layer effectively |
| 14 | [Testing Strategy](#14-testing-strategy) | Unit tests, UI tests, screenshot tests, and benchmarks |
| 15 | [Build Configuration](#15-build-configuration) | Convention plugins, version catalog, Gradle optimization |
| 16 | [Performance Optimization](#16-performance-optimization) | Baseline profiles, jank tracking, Compose compiler configuration |
| 17 | [Analytics & Monitoring](#17-analytics--monitoring) | Analytics abstraction, tracing, structured error handling |
| 18 | [Accessibility](#18-accessibility) | Built-in patterns, semantic modifiers, screen reader support |
| 19 | [CI/CD Pipeline](#19-cicd-pipeline) | GitHub Actions, lint integration, dependency guard |
| 20 | [Best Practices Summary](#20-best-practices-summary) | Key patterns, anti-patterns, and decision guidelines |

---

## 1. Introduction

### What is Now in Android?

Now in Android (NiA) is Google's official reference implementation demonstrating modern Android development best practices. It showcases:

- **Official Android Architecture** - Three-layer architecture (Data, Domain, UI)
- **Jetpack Compose** - Entire UI built with Compose
- **Kotlin Coroutines & Flow** - Reactive programming throughout
- **Offline-First Design** - Local database as source of truth
- **Multi-Module Architecture** - 35+ modules with clear separation

### Key Architectural Principles

```
┌─────────────────────────────────┐
│         UI LAYER                │  Jetpack Compose + ViewModels
├─────────────────────────────────┤
│      DOMAIN LAYER               │  Use Cases (optional)
├─────────────────────────────────┤
│       DATA LAYER                │  Repositories + Data Sources
└─────────────────────────────────┘
```

**Core Principles:**
1. **Unidirectional Data Flow (UDF)** - Data flows up, events flow down
2. **Single Source of Truth** - Room database is authoritative
3. **Separation of Concerns** - Each layer has distinct responsibilities
4. **Testability** - Dependency injection enables comprehensive testing

### KMP Note
Many patterns in this guide translate directly to Kotlin Multiplatform:
- Repository pattern works unchanged
- Use cases are pure Kotlin
- Flow-based reactivity is KMP-compatible
- Only UI layer requires platform-specific implementation

---

## 2. Module Architecture

### Module Organization

NiA uses a sophisticated multi-module architecture with 35+ modules:

```
project/
├── app/                    # Application entry point
├── core/                   # Shared functionality
│   ├── model/             # Domain models (pure Kotlin)
│   ├── data/              # Repository implementations
│   ├── domain/            # Use cases
│   ├── database/          # Room database
│   ├── datastore/         # Proto DataStore
│   ├── network/           # Retrofit networking
│   ├── ui/                # Shared UI components
│   ├── designsystem/      # Design system (theme, components)
│   ├── navigation/        # Navigation infrastructure
│   ├── common/            # Utilities, dispatchers
│   ├── analytics/         # Analytics abstraction
│   ├── notifications/     # Notification handling
│   └── testing/           # Test utilities
├── feature/               # Feature modules
│   ├── foryou/           # For You screen
│   │   ├── api/          # Navigation keys only
│   │   └── impl/         # UI, ViewModel, logic
│   ├── interests/
│   ├── bookmarks/
│   ├── topic/
│   ├── search/
│   └── settings/
├── sync/                  # Background synchronization
│   └── work/             # WorkManager implementation
└── build-logic/          # Gradle convention plugins
```

### Module Types

**Core Modules** - Shared infrastructure:
- `core:model` - Pure Kotlin domain models (JVM library)
- `core:data` - Repository implementations with sync
- `core:database` - Room DAOs and entities
- `core:network` - API clients and network models
- `core:designsystem` - Material 3 wrapped components

**Feature Modules** - UI features split into API/Impl:
- `feature:xyz:api` - Navigation keys and route definitions
- `feature:xyz:impl` - Composables, ViewModels, business logic

**Sync Modules** - Background operations:
- `sync:work` - WorkManager-based data synchronization

### API/Impl Split Pattern

Feature modules use API/Impl separation to prevent circular dependencies:

```kotlin
// feature/foryou/api - Lightweight, exposes navigation only
@Serializable
object ForYouNavKey : NavKey

// feature/foryou/impl - Full implementation
@HiltViewModel
class ForYouViewModel @Inject constructor(...) : ViewModel()

@Composable
fun ForYouScreen(viewModel: ForYouViewModel = hiltViewModel())
```

**Benefits:**
- Features can navigate to each other via API modules
- Implementation details remain hidden
- Build times improve (API modules rarely change)
- Clear dependency direction

### Module Dependencies

```
app → feature:*/impl → feature:*/api
         ↓                    ↓
      core:ui            core:navigation
         ↓
    core:domain
         ↓
    core:data → core:database
                core:network
                core:datastore
```

**Rules:**
- Features depend on other features' APIs, never implementations
- Core modules don't depend on features
- All modules can depend on `core:model`

### KMP Note
Module structure translates well to KMP:
- `core:model`, `core:domain` → Pure Kotlin (commonMain)
- `core:data` → Mostly common with expect/actual for platform sources
- `core:database` → Room supports KMP
- `core:network` → Ktor for cross-platform
- Feature modules → Platform-specific UI

---

## 3. Layer Architecture

### Three-Layer Architecture

```
┌────────────────────────────────────────────────────────────┐
│                        UI LAYER                             │
│  ┌─────────────┐    ┌───────────────┐    ┌──────────────┐ │
│  │ Composables │ ←→ │   ViewModel   │ ←─ │   UiState    │ │
│  └─────────────┘    └───────────────┘    └──────────────┘ │
├────────────────────────────────────────────────────────────┤
│                      DOMAIN LAYER                           │
│  ┌───────────────────────────────────────────────────────┐ │
│  │                     Use Cases                          │ │
│  │         (combine data from multiple sources)           │ │
│  └───────────────────────────────────────────────────────┘ │
├────────────────────────────────────────────────────────────┤
│                       DATA LAYER                            │
│  ┌─────────────┐    ┌─────────────┐    ┌───────────────┐  │
│  │ Repository  │ ←─ │    Room     │    │   Retrofit    │  │
│  │ (interface) │    │  Database   │    │   Network     │  │
│  └─────────────┘    └─────────────┘    └───────────────┘  │
│                           ↑                                 │
│                     ┌─────────────┐                        │
│                     │  DataStore  │                        │
│                     └─────────────┘                        │
└────────────────────────────────────────────────────────────┘
```

### Data Flow

**Data Flows Up (Reactive):**
```
Database → Repository → UseCase → ViewModel → StateFlow → Composable
           (Flow)       (Flow)    (combine)   (stateIn)   (collect)
```

**Events Flow Down (Imperative):**
```
Composable → ViewModel → Repository → Database/Network
(onClick)    (method)    (suspend)    (write)
```

### UI State Pattern

Use sealed interfaces for exhaustive state handling:

```kotlin
sealed interface NewsFeedUiState {
    data object Loading : NewsFeedUiState
    data class Success(val feed: List<UserNewsResource>) : NewsFeedUiState
    data class Error(val message: String) : NewsFeedUiState
}
```

**Benefits:**
- Compiler enforces handling all states
- Clear state transitions
- Easy to test state changes

### ViewModel Pattern

```kotlin
@HiltViewModel
class ForYouViewModel @Inject constructor(
    private val userNewsResourceRepository: UserNewsResourceRepository,
) : ViewModel() {

    val feedState: StateFlow<NewsFeedUiState> =
        userNewsResourceRepository.observeAllForFollowedTopics()
            .map(NewsFeedUiState::Success)
            .stateIn(
                scope = viewModelScope,
                started = SharingStarted.WhileSubscribed(5_000),
                initialValue = NewsFeedUiState.Loading,
            )

    fun bookmarkNews(newsId: String, bookmarked: Boolean) {
        viewModelScope.launch {
            userNewsResourceRepository.setNewsResourceBookmarked(newsId, bookmarked)
        }
    }
}
```

**Key Pattern:** `stateIn()` with `WhileSubscribed(5_000)`:
- Keeps flow active 5 seconds after last subscriber
- Prevents restarting during configuration changes
- Releases resources when truly inactive

### KMP Note
- UI State sealed interfaces work unchanged in commonMain
- ViewModel pattern needs platform abstraction (use `ViewModel` on Android, regular class elsewhere)
- Repository/UseCase layer is fully portable

---

## 4. Dependency Injection

### Hilt Configuration

NiA uses Hilt with KSP (Kotlin Symbol Processing) for DI:

```kotlin
// app/build.gradle.kts
plugins {
    alias(libs.plugins.nowinandroid.hilt)
}

// Convention plugin applies:
// - dagger.hilt.android
// - ksp
// - hilt-android dependency
// - hilt-compiler via KSP
```

### Module Organization

**Database Module** - Singleton database:
```kotlin
@Module
@InstallIn(SingletonComponent::class)
internal object DatabaseModule {
    @Provides
    @Singleton
    fun providesNiaDatabase(@ApplicationContext context: Context): NiaDatabase =
        Room.databaseBuilder(context, NiaDatabase::class.java, "nia-database").build()
}
```

**DAOs Module** - Database accessors:
```kotlin
@Module
@InstallIn(SingletonComponent::class)
internal object DaosModule {
    @Provides
    fun providesNewsResourceDao(database: NiaDatabase): NewsResourceDao =
        database.newsResourceDao()
}
```

**Data Module** - Repository bindings:
```kotlin
@Module
@InstallIn(SingletonComponent::class)
abstract class DataModule {
    @Binds
    internal abstract fun bindsNewsRepository(
        impl: OfflineFirstNewsRepository,
    ): NewsRepository
}
```

### Constructor Injection Pattern

```kotlin
internal class OfflineFirstNewsRepository @Inject constructor(
    private val newsResourceDao: NewsResourceDao,
    private val network: NiaNetworkDataSource,
    private val notifier: Notifier,
) : NewsRepository {
    // Implementation
}
```

**Best Practice:** Use `internal` visibility for implementation classes.

### Custom Dispatchers

```kotlin
enum class NiaDispatchers { Default, IO }

@Qualifier
@Retention(AnnotationRetention.RUNTIME)
annotation class Dispatcher(val niaDispatcher: NiaDispatchers)

// Usage
class Repository @Inject constructor(
    @Dispatcher(IO) private val ioDispatcher: CoroutineDispatcher,
)
```

### ViewModel Injection

```kotlin
@HiltViewModel
class BookmarksViewModel @Inject constructor(
    private val userDataRepository: UserDataRepository,
    private val userNewsResourceRepository: UserNewsResourceRepository,
) : ViewModel()

// In Composable
@Composable
fun BookmarksScreen(viewModel: BookmarksViewModel = hiltViewModel())
```

### Flavor-Based Bindings

Different implementations per build flavor:

```kotlin
// src/demo/kotlin/di/FlavoredNetworkModule.kt
@Module
@InstallIn(SingletonComponent::class)
internal interface FlavoredNetworkModule {
    @Binds
    fun binds(impl: DemoNiaNetworkDataSource): NiaNetworkDataSource
}

// src/prod/kotlin/di/FlavoredNetworkModule.kt
@Module
@InstallIn(SingletonComponent::class)
internal interface FlavoredNetworkModule {
    @Binds
    fun binds(impl: RetrofitNiaNetwork): NiaNetworkDataSource
}
```

### Testing with Hilt

```kotlin
@HiltAndroidTest
class NavigationTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @Inject
    lateinit var newsRepository: NewsRepository

    @Before
    fun setup() = hiltRule.inject()
}
```

### KMP Note
Hilt is Android-only. For KMP:
- Use Koin or manual DI
- Abstract DI setup behind interfaces
- Platform-specific DI configuration

---

## 5. Compose UI Fundamentals

### Component Design Pattern

Wrap Material 3 components with app-specific defaults:

```kotlin
@Composable
fun NiaButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    text: @Composable () -> Unit,
    leadingIcon: @Composable (() -> Unit)? = null,
) {
    Button(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        colors = ButtonDefaults.buttonColors(
            containerColor = MaterialTheme.colorScheme.onBackground,
        ),
        contentPadding = if (leadingIcon != null) {
            ButtonDefaults.ButtonWithIconContentPadding
        } else {
            ButtonDefaults.ContentPadding
        },
    ) {
        NiaButtonContent(text = text, leadingIcon = leadingIcon)
    }
}
```

**Benefits:**
- Consistent styling across app
- Easy to modify globally
- Enforced via custom lint rules

### State Hoisting Pattern

Separate stateful and stateless composables:

```kotlin
// Public - injected ViewModel
@Composable
fun ForYouScreen(
    onTopicClick: (String) -> Unit,
    modifier: Modifier = Modifier,
    viewModel: ForYouViewModel = hiltViewModel(),
) {
    val feedState by viewModel.feedState.collectAsStateWithLifecycle()

    ForYouScreen(
        feedState = feedState,
        onTopicClick = onTopicClick,
        onBookmarkChange = viewModel::bookmarkNews,
        modifier = modifier,
    )
}

// Internal - stateless, testable
@Composable
internal fun ForYouScreen(
    feedState: NewsFeedUiState,
    onTopicClick: (String) -> Unit,
    onBookmarkChange: (String, Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Pure UI rendering based on state
}
```

### Collecting State

Always use lifecycle-aware collection:

```kotlin
val feedState by viewModel.feedState.collectAsStateWithLifecycle()
```

**Why:** Stops collection when UI is not visible, preventing unnecessary work.

### Loading States

```kotlin
@Composable
fun NiaLoadingWheel(
    contentDesc: String,
    modifier: Modifier = Modifier,
) {
    // Custom animated loading indicator
}

@Composable
fun NiaOverlayLoadingWheel(contentDesc: String) {
    Surface(color = MaterialTheme.colorScheme.surface.copy(alpha = 0.83f)) {
        NiaLoadingWheel(contentDesc)
    }
}
```

### Image Loading

```kotlin
@Composable
fun DynamicAsyncImage(
    imageUrl: String,
    contentDescription: String?,
    modifier: Modifier = Modifier,
) {
    var isLoading by remember { mutableStateOf(true) }
    var isError by remember { mutableStateOf(false) }

    val painter = rememberAsyncImagePainter(
        model = imageUrl,
        onState = { state ->
            isLoading = state is Loading
            isError = state is Error
        },
    )

    Box(modifier) {
        if (isLoading) CircularProgressIndicator()
        Image(painter = painter, contentDescription = contentDescription)
    }
}
```

### Preview Annotations

Multi-device previews:

```kotlin
@Preview(name = "phone", device = "spec:shape=Normal,width=360,height=640,unit=dp,dpi=480")
@Preview(name = "foldable", device = "spec:shape=Normal,width=673,height=841,unit=dp,dpi=480")
@Preview(name = "tablet", device = "spec:shape=Normal,width=1280,height=800,unit=dp,dpi=480")
annotation class DevicePreviews

// Usage
@DevicePreviews
@Composable
fun ForYouScreenPreview() { ... }
```

Multi-theme previews:

```kotlin
@Preview(name = "Light")
@Preview(name = "Dark", uiMode = UI_MODE_NIGHT_YES)
annotation class ThemePreviews
```

---

## 6. Design System

### Theme Architecture

```kotlin
@Composable
fun NiaTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    androidTheme: Boolean = false,
    disableDynamicTheming: Boolean = false,
    content: @Composable () -> Unit,
) {
    val colorScheme = when {
        !disableDynamicTheming && supportsDynamicTheming() -> {
            if (darkTheme) dynamicDarkColorScheme(context)
            else dynamicLightColorScheme(context)
        }
        androidTheme && darkTheme -> DarkAndroidColorScheme
        androidTheme -> LightAndroidColorScheme
        darkTheme -> DarkDefaultColorScheme
        else -> LightDefaultColorScheme
    }

    CompositionLocalProvider(
        LocalGradientColors provides gradientColors,
        LocalBackgroundTheme provides backgroundTheme,
        LocalTintTheme provides tintTheme,
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = NiaTypography,
            content = content,
        )
    }
}
```

### Custom Composition Locals

```kotlin
// Define
val LocalBackgroundTheme = staticCompositionLocalOf { BackgroundTheme() }
val LocalGradientColors = staticCompositionLocalOf { GradientColors() }
val LocalTintTheme = staticCompositionLocalOf { TintTheme() }

// Access
@Composable
fun MyComponent() {
    val gradientColors = LocalGradientColors.current
    val iconTint = LocalTintTheme.current.iconTint
}
```

**Use `staticCompositionLocalOf`** for values that rarely change (themes).

### Color System

Organize colors by family with numbered shades:

```kotlin
// Colors.kt
val Purple10 = Color(0xFF36003D)
val Purple20 = Color(0xFF560A5E)
val Purple40 = Color(0xFF8B418F)
val Purple80 = Color(0xFFFFA8FF)
val Purple90 = Color(0xFFFFD5FA)

// Color schemes
val LightDefaultColorScheme = lightColorScheme(
    primary = Purple40,
    onPrimary = Color.White,
    primaryContainer = Purple90,
    // ...
)
```

### Typography

```kotlin
val NiaTypography = Typography(
    displayLarge = TextStyle(
        fontWeight = FontWeight.W400,
        fontSize = 57.sp,
        lineHeight = 64.sp,
        letterSpacing = (-0.25).sp,
    ),
    // Define all type scales...
)
```

### Gradient Background

```kotlin
@Composable
fun NiaGradientBackground(
    modifier: Modifier = Modifier,
    gradientColors: GradientColors = LocalGradientColors.current,
    content: @Composable () -> Unit,
) {
    Surface(modifier) {
        Box(
            Modifier.drawWithCache {
                val topGradient = Brush.linearGradient(
                    0f to gradientColors.top,
                    0.724f to Color.Transparent,
                )
                onDrawBehind {
                    drawRect(topGradient)
                }
            }
        ) {
            content()
        }
    }
}
```

### Custom Components Enforced by Lint

Custom lint rule enforces design system usage:

```kotlin
// Detects direct Material usage
class DesignSystemDetector : Detector(), SourceCodeScanner {
    companion object {
        val ISSUE = Issue.create(
            id = "DesignSystem",
            briefDescription = "Use NiA design system components",
            explanation = "Use NiaButton instead of Button, NiaTheme instead of MaterialTheme",
        )
    }
    // Maps: Button → NiaButton, MaterialTheme → NiaTheme, etc.
}
```

---

## 7. State Management

### Lifecycle and operation results

Expose observable UI facts such as `isCreated`, `isDeleted`, and write errors as
state. A ViewModel must not retain a screen's navigation callback while a
repository operation suspends. The route observes completion and navigates only
when its lifecycle is resumed; content composables remain stateless.

Use `SavedStateHandle` for small editable drafts and `rememberSaveable` for local
UI state. Neither replaces database persistence, a durable work queue, or backend
idempotency. Re-throw `CancellationException`; translate other write failures into
safe, actionable UI messages. Claim an operation before launching its coroutine
to prevent rapid taps from queuing duplicate submissions.

The Tasks create/detail screens demonstrate these boundaries. See Google's
[UI event guidance](https://developer.android.com/topic/architecture/ui-layer/events).

### StateFlow Pattern

```kotlin
@HiltViewModel
class SearchViewModel @Inject constructor(
    private val getSearchContents: GetSearchContentsUseCase,
    private val recentSearchRepository: RecentSearchRepository,
) : ViewModel() {

    val searchQuery = MutableStateFlow("")

    val searchResultUiState: StateFlow<SearchResultUiState> =
        searchQuery
            .debounce(200)
            .distinctUntilChanged()
            .flatMapLatest { query ->
                if (query.length < 2) {
                    flowOf(SearchResultUiState.EmptyQuery)
                } else {
                    getSearchContents(query)
                        .map { SearchResultUiState.Success(it) }
                        .catch { emit(SearchResultUiState.LoadFailed) }
                }
            }
            .stateIn(
                scope = viewModelScope,
                started = SharingStarted.WhileSubscribed(5_000),
                initialValue = SearchResultUiState.Loading,
            )

    fun onSearchQueryChanged(query: String) {
        searchQuery.value = query
    }
}
```

### Combining Multiple Streams

```kotlin
val uiState: StateFlow<ForYouUiState> = combine(
    onboardingState,
    feedState,
    isSyncing,
) { onboarding, feed, syncing ->
    ForYouUiState(
        onboarding = onboarding,
        feed = feed,
        isSyncing = syncing,
    )
}.stateIn(...)
```

### UI State Sealed Hierarchy

```kotlin
sealed interface OnboardingUiState {
    data object Loading : OnboardingUiState
    data object NotShown : OnboardingUiState
    data class Shown(val topics: List<FollowableTopic>) : OnboardingUiState
}

// Exhaustive when
when (state) {
    OnboardingUiState.Loading -> LoadingIndicator()
    OnboardingUiState.NotShown -> { /* Empty */ }
    is OnboardingUiState.Shown -> TopicSelector(state.topics)
}
```

### SavedStateHandle for Deep Links

```kotlin
@HiltViewModel
class TopicViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    topicsRepository: TopicsRepository,
) : ViewModel() {

    private val topicId: String = savedStateHandle["topicId"] ?: ""

    val topicState: StateFlow<TopicUiState> =
        topicsRepository.getTopic(topicId)
            .map(TopicUiState::Success)
            .stateIn(...)
}
```

### Result Wrapper

```kotlin
sealed interface Result<out T> {
    data class Success<T>(val data: T) : Result<T>
    data class Error(val exception: Throwable) : Result<Nothing>
    data object Loading : Result<Nothing>
}

fun <T> Flow<T>.asResult(): Flow<Result<T>> =
    map<T, Result<T>> { Result.Success(it) }
        .onStart { emit(Result.Loading) }
        .catch { emit(Result.Error(it)) }
```

### KMP Note
StateFlow and sealed interfaces work unchanged in KMP. ViewModel needs abstraction:
- Use `expect class ViewModel` with `actual` implementations
- Or use a cross-platform state holder library

---

## 8. Navigation

### Navigation3 Architecture

NiA uses Navigation3 with multi-level back stacks:

```kotlin
@Composable
fun rememberNavigationState(
    startKey: NavKey,
    topLevelKeys: Set<NavKey>,
): NavigationState {
    val topLevelStack = rememberNavBackStack(startKey)
    val subStacks = topLevelKeys.associateWith { rememberNavBackStack(it) }

    return remember {
        NavigationState(
            startKey = startKey,
            topLevelStack = topLevelStack,
            subStacks = subStacks,
        )
    }
}
```

### Type-Safe Navigation Keys

```kotlin
// feature/foryou/api
@Serializable
object ForYouNavKey : NavKey

// feature/topic/api
@Serializable
data class TopicNavKey(val topicId: String) : NavKey
```

### Navigator Pattern

```kotlin
class Navigator(val state: NavigationState) {
    fun navigate(key: NavKey) {
        when (key) {
            state.currentTopLevelKey -> clearSubStack()
            in state.topLevelKeys -> goToTopLevel(key)
            else -> goToKey(key)
        }
    }

    fun goBack() {
        // Handle hierarchical back navigation
    }
}

// Extension for navigation
fun Navigator.navigateToTopic(topicId: String) {
    navigate(TopicNavKey(topicId))
}
```

### Adaptive Navigation

```kotlin
@Composable
fun NiaApp(windowAdaptiveInfo: WindowAdaptiveInfo) {
    NiaNavigationSuiteScaffold(
        navigationSuiteItems = {
            TOP_LEVEL_NAV_ITEMS.forEach { (navKey, navItem) ->
                item(
                    selected = navKey == appState.currentTopLevelKey,
                    onClick = { navigator.navigate(navKey) },
                    icon = { Icon(navItem.icon, null) },
                    label = { Text(navItem.title) },
                )
            }
        },
    ) {
        NavDisplay(entries = navigationState.toEntries(entryProvider))
    }
}
```

`NiaNavigationSuiteScaffold` adapts between:
- **Phone**: Bottom navigation bar
- **Tablet/Foldable**: Navigation rail
- **Large screen**: Navigation drawer

### Deep Linking

```kotlin
const val DEEP_LINK_BASE_PATH = "https://www.nowinandroid.apps.samples.google.com/foryou"
const val DEEP_LINK_NEWS_RESOURCE_ID_KEY = "linkedNewsResourceId"

// In ViewModel
private val linkedNewsResourceId: String? = savedStateHandle[DEEP_LINK_NEWS_RESOURCE_ID_KEY]
```

---

## 9. Data Layer

### Repository Interface

```kotlin
interface NewsRepository : Syncable {
    fun getNewsResources(
        query: NewsResourceQuery = NewsResourceQuery(),
    ): Flow<List<NewsResource>>
}

data class NewsResourceQuery(
    val filterTopicIds: Set<String>? = null,
    val filterNewsIds: Set<String>? = null,
)
```

### Room Database

```kotlin
@Database(
    entities = [
        NewsResourceEntity::class,
        NewsResourceTopicCrossRef::class,
        TopicEntity::class,
        RecentSearchQueryEntity::class,
    ],
    version = 14,
    autoMigrations = [
        AutoMigration(from = 1, to = 2),
        // ...
    ],
    exportSchema = true,
)
@TypeConverters(InstantConverter::class)
internal abstract class NiaDatabase : RoomDatabase() {
    abstract fun newsResourceDao(): NewsResourceDao
    abstract fun topicDao(): TopicDao
}
```

### DAO Pattern

```kotlin
@Dao
interface NewsResourceDao {
    @Transaction
    @Query("""
        SELECT * FROM news_resources
        WHERE CASE WHEN :useFilterTopicIds
            THEN id IN (SELECT news_resource_id FROM news_resources_topics
                        WHERE topic_id IN (:filterTopicIds))
            ELSE 1 END
        ORDER BY publish_date DESC
    """)
    fun getNewsResources(
        useFilterTopicIds: Boolean = false,
        filterTopicIds: Set<String> = emptySet(),
    ): Flow<List<PopulatedNewsResource>>

    @Upsert
    suspend fun upsertNewsResources(entities: List<NewsResourceEntity>)

    @Query("DELETE FROM news_resources WHERE id in (:ids)")
    suspend fun deleteNewsResources(ids: List<String>)
}
```

### Entity with Relations

```kotlin
data class PopulatedNewsResource(
    @Embedded
    val entity: NewsResourceEntity,
    @Relation(
        parentColumn = "id",
        entityColumn = "id",
        associateBy = Junction(
            value = NewsResourceTopicCrossRef::class,
            parentColumn = "news_resource_id",
            entityColumn = "topic_id",
        ),
    )
    val topics: List<TopicEntity>,
)

fun PopulatedNewsResource.asExternalModel() = NewsResource(
    id = entity.id,
    title = entity.title,
    topics = topics.map(TopicEntity::asExternalModel),
    // ...
)
```

### Proto DataStore

```protobuf
// user_preferences.proto
message UserPreferences {
    map<string, bool> followed_topic_ids = 13;
    map<string, bool> bookmarked_news_resource_ids = 15;
    int32 topicChangeListVersion = 3;
    int32 newsResourceChangeListVersion = 6;
    ThemeBrandProto theme_brand = 16;
    DarkThemeConfigProto dark_theme_config = 17;
    bool should_hide_onboarding = 18;
}
```

```kotlin
class NiaPreferencesDataSource @Inject constructor(
    private val userPreferences: DataStore<UserPreferences>,
) {
    val userData: Flow<UserData> = userPreferences.data.map { prefs ->
        UserData(
            followedTopics = prefs.followedTopicIdsMap.keys,
            bookmarkedNewsResources = prefs.bookmarkedNewsResourceIdsMap.keys,
            // ...
        )
    }

    suspend fun setTopicIdFollowed(topicId: String, followed: Boolean) {
        userPreferences.updateData { prefs ->
            prefs.toBuilder().apply {
                if (followed) putFollowedTopicIds(topicId, true)
                else removeFollowedTopicIds(topicId)
            }.build()
        }
    }
}
```

### Three-Layer Model Pattern

```
Network Models → Database Entities → Domain Models
(API response)   (Room storage)      (UI/UseCase)
```

```kotlin
// Network → Entity
fun NetworkNewsResource.asEntity() = NewsResourceEntity(...)

// Entity → Domain
fun NewsResourceEntity.asExternalModel() = NewsResource(...)
```

### KMP Note
- Room now supports KMP
- Proto DataStore works with KMP
- Model conversion pattern unchanged

---

## 10. Network Layer

### Network Interface

```kotlin
interface NiaNetworkDataSource {
    suspend fun getTopics(ids: List<String>? = null): List<NetworkTopic>
    suspend fun getNewsResources(ids: List<String>? = null): List<NetworkNewsResource>
    suspend fun getTopicChangeList(after: Int? = null): List<NetworkChangeList>
    suspend fun getNewsResourceChangeList(after: Int? = null): List<NetworkChangeList>
}
```

### Retrofit Implementation

```kotlin
@Singleton
internal class RetrofitNiaNetwork @Inject constructor(
    networkJson: Json,
    okhttpCallFactory: dagger.Lazy<Call.Factory>,
) : NiaNetworkDataSource {

    private val networkApi = trace("RetrofitNiaNetwork") {
        Retrofit.Builder()
            .baseUrl(NIA_BASE_URL)
            .callFactory { okhttpCallFactory.get().newCall(it) }
            .addConverterFactory(networkJson.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(RetrofitNiaNetworkApi::class.java)
    }

    override suspend fun getNewsResources(ids: List<String>?) =
        networkApi.getNewsResources(ids = ids).data
}

private interface RetrofitNiaNetworkApi {
    @GET("newsresources")
    suspend fun getNewsResources(
        @Query("id") ids: List<String>?,
    ): NetworkResponse<List<NetworkNewsResource>>
}
```

**Note:** Uses `dagger.Lazy<Call.Factory>` to prevent OkHttp initialization on main thread.

### Network Models

```kotlin
@Serializable
data class NetworkNewsResource(
    val id: String,
    val title: String,
    val content: String,
    val url: String,
    val headerImageUrl: String,
    val publishDate: Instant,
    val type: String,
    val topics: List<String> = emptyList(),
)

@Serializable
data class NetworkChangeList(
    val id: String,
    val changeListVersion: Int,
    val isDelete: Boolean,
)
```

### Demo Implementation

For development without network:

```kotlin
class DemoNiaNetworkDataSource @Inject constructor(
    @Dispatcher(IO) private val ioDispatcher: CoroutineDispatcher,
    private val networkJson: Json,
    private val assets: DemoAssetManager,
) : NiaNetworkDataSource {

    override suspend fun getNewsResources(ids: List<String>?) =
        withContext(ioDispatcher) {
            assets.open(NEWS_ASSET).use { stream ->
                networkJson.decodeFromString<List<NetworkNewsResource>>(stream.readBytes().decodeToString())
            }
        }
}
```

### Network Module

```kotlin
@Module
@InstallIn(SingletonComponent::class)
internal object NetworkModule {
    @Provides
    @Singleton
    fun providesNetworkJson(): Json = Json { ignoreUnknownKeys = true }

    @Provides
    @Singleton
    fun okHttpCallFactory(): Call.Factory = OkHttpClient.Builder()
        .addInterceptor(HttpLoggingInterceptor().apply {
            if (BuildConfig.DEBUG) setLevel(Level.BODY)
        })
        .build()
}
```

### KMP Note
Replace Retrofit with Ktor for cross-platform networking:
```kotlin
// commonMain
expect class HttpClient
suspend fun getNewsResources(): List<NetworkNewsResource>
```

---

## 11. Offline-First Architecture

### Core Principle

**Local database is the single source of truth.**

```
┌───────────────────────────────────────────────────┐
│                      UI                            │
│                       ↑                            │
│               Flow<List<News>>                     │
│                       │                            │
│              ┌────────┴────────┐                  │
│              │   Repository    │                  │
│              └────────┬────────┘                  │
│                       │                            │
│    ┌──────────────────┴──────────────────┐       │
│    ↓                                      ↓       │
│ ┌──────────┐                      ┌──────────┐   │
│ │   Room   │←─── sync ───────────→│ Network  │   │
│ │ Database │                      │   API    │   │
│ └──────────┘                      └──────────┘   │
└───────────────────────────────────────────────────┘
```

### Repository Implementation

```kotlin
internal class OfflineFirstNewsRepository @Inject constructor(
    private val newsResourceDao: NewsResourceDao,
    private val network: NiaNetworkDataSource,
    private val notifier: Notifier,
) : NewsRepository {

    // All reads from local database
    override fun getNewsResources(query: NewsResourceQuery): Flow<List<NewsResource>> =
        newsResourceDao.getNewsResources(
            useFilterTopicIds = query.filterTopicIds != null,
            filterTopicIds = query.filterTopicIds ?: emptySet(),
        ).map { it.map(PopulatedNewsResource::asExternalModel) }
}
```

### Benefits

1. **Works Offline** - Users access data without network
2. **Fast UI** - No network latency for reads
3. **Resilient** - Network failures don't break the app
4. **Consistent** - Single source prevents stale data conflicts

### Sync Updates Database

Network data only enters through sync:

```kotlin
override suspend fun syncWith(synchronizer: Synchronizer): Boolean =
    synchronizer.changeListSync(
        versionReader = ChangeListVersions::newsResourceVersion,
        changeListFetcher = { version ->
            network.getNewsResourceChangeList(after = version)
        },
        modelDeleter = newsResourceDao::deleteNewsResources,
        modelUpdater = { changedIds ->
            val resources = network.getNewsResources(ids = changedIds)
            newsResourceDao.upsertNewsResources(resources.map { it.asEntity() })
        },
        versionUpdater = { version ->
            copy(newsResourceVersion = version)
        },
    )
```

### DataStore for User Preferences

User data stored locally, never synced to network:

```kotlin
class OfflineFirstUserDataRepository @Inject constructor(
    private val niaPreferences: NiaPreferencesDataSource,
) : UserDataRepository {

    override val userData: Flow<UserData> = niaPreferences.userData

    override suspend fun setTopicIdFollowed(topicId: String, followed: Boolean) {
        niaPreferences.setTopicIdFollowed(topicId, followed)
    }
}
```

---

## 12. Background Sync

### Synchronizer Pattern

```kotlin
interface Synchronizer {
    suspend fun getChangeListVersions(): ChangeListVersions
    suspend fun updateChangeListVersions(update: ChangeListVersions.() -> ChangeListVersions)
    suspend fun Syncable.sync() = this@sync.syncWith(this@Synchronizer)
}

interface Syncable {
    suspend fun syncWith(synchronizer: Synchronizer): Boolean
}
```

### Change List Sync Algorithm

Efficient incremental sync using version numbers:

```kotlin
suspend fun Synchronizer.changeListSync(
    versionReader: (ChangeListVersions) -> Int,
    changeListFetcher: suspend (Int) -> List<NetworkChangeList>,
    versionUpdater: ChangeListVersions.(Int) -> ChangeListVersions,
    modelDeleter: suspend (List<String>) -> Unit,
    modelUpdater: suspend (List<String>) -> Unit,
) = suspendRunCatching {
    // 1. Get current version
    val currentVersion = versionReader(getChangeListVersions())

    // 2. Fetch changes since version
    val changeList = changeListFetcher(currentVersion)
    if (changeList.isEmpty()) return@suspendRunCatching true

    // 3. Partition into deletions and updates
    val (deleted, updated) = changeList.partition { it.isDelete }

    // 4. Apply deletions
    modelDeleter(deleted.map { it.id })

    // 5. Fetch and apply updates
    modelUpdater(updated.map { it.id })

    // 6. Update version
    updateChangeListVersions { versionUpdater(changeList.last().changeListVersion) }
}.isSuccess
```

### WorkManager Integration

```kotlin
@HiltWorker
internal class SyncWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted workerParams: WorkerParameters,
    private val topicRepository: TopicsRepository,
    private val newsRepository: NewsRepository,
    @Dispatcher(IO) private val ioDispatcher: CoroutineDispatcher,
) : CoroutineWorker(context, workerParams), Synchronizer {

    override suspend fun doWork(): Result = withContext(ioDispatcher) {
        traceAsync("Sync", 0) {
            // Sync repositories in parallel
            val syncedSuccessfully = awaitAll(
                async { topicRepository.sync() },
                async { newsRepository.sync() },
            ).all { it }

            if (syncedSuccessfully) Result.success()
            else Result.retry()
        }
    }

    companion object {
        fun startUpSyncWork() = OneTimeWorkRequestBuilder<DelegatingWorker>()
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setConstraints(Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build())
            .build()
    }
}
```

### Sync Initialization

```kotlin
object Sync {
    fun initialize(context: Context) {
        WorkManager.getInstance(context).enqueueUniqueWork(
            SYNC_WORK_NAME,
            ExistingWorkPolicy.KEEP,
            SyncWorker.startUpSyncWork(),
        )
    }
}

// In Application.onCreate()
class NiaApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Sync.initialize(this)
    }
}
```

### Sync Status Monitoring

```kotlin
class WorkManagerSyncManager @Inject constructor(
    @ApplicationContext private val context: Context,
) : SyncManager {
    override val isSyncing: Flow<Boolean> =
        WorkManager.getInstance(context)
            .getWorkInfosForUniqueWorkFlow(SYNC_WORK_NAME)
            .map { workInfos -> workInfos.any { it.state == State.RUNNING } }
            .conflate()
}

// In ViewModel
val isSyncing: StateFlow<Boolean> = syncManager.isSyncing.stateIn(...)

// In UI
if (isSyncing) LinearProgressIndicator()
```

### KMP Note
WorkManager is Android-only. For KMP:
- Use platform-specific background work
- iOS: BGTaskScheduler
- Abstract behind common interface

---

## 13. Domain Use Cases

### When to Use Domain Layer

Use cases are **optional** but recommended when:
1. Combining data from multiple repositories
2. Complex business logic needs isolation
3. Same logic used by multiple ViewModels

### Use Case Pattern

```kotlin
class GetFollowableTopicsUseCase @Inject constructor(
    private val topicsRepository: TopicsRepository,
    private val userDataRepository: UserDataRepository,
) {
    operator fun invoke(sortBy: TopicSortField = NONE): Flow<List<FollowableTopic>> =
        combine(
            userDataRepository.userData,
            topicsRepository.getTopics(),
        ) { userData, topics ->
            topics.map { topic ->
                FollowableTopic(
                    topic = topic,
                    isFollowed = topic.id in userData.followedTopics,
                )
            }.sortedBy(sortBy)
        }
}
```

### Callable as Function

```kotlin
// In ViewModel
val topics: StateFlow<List<FollowableTopic>> =
    getFollowableTopics(sortBy = NAME)  // Direct invocation
        .stateIn(...)
```

### Search Use Case

```kotlin
class GetSearchContentsUseCase @Inject constructor(
    private val searchContentsRepository: SearchContentsRepository,
    private val userDataRepository: UserDataRepository,
) {
    operator fun invoke(searchQuery: String): Flow<UserSearchResult> =
        searchContentsRepository.searchContents(searchQuery)
            .combine(userDataRepository.userData) { results, userData ->
                results.toUserSearchResult(userData)
            }
}

private fun SearchResult.toUserSearchResult(userData: UserData) = UserSearchResult(
    topics = topics.map { FollowableTopic(it, it.id in userData.followedTopics) },
    newsResources = newsResources.map { UserNewsResource(it, it.id in userData.bookmarkedNewsResources) },
)
```

### Composite Repository Alternative

When use case just combines repositories, consider Composite Repository:

```kotlin
class CompositeUserNewsResourceRepository @Inject constructor(
    private val newsRepository: NewsRepository,
    private val userDataRepository: UserDataRepository,
) : UserNewsResourceRepository {

    override fun observeAll(query: NewsResourceQuery): Flow<List<UserNewsResource>> =
        newsRepository.getNewsResources(query)
            .combine(userDataRepository.userData) { news, userData ->
                news.map { resource ->
                    UserNewsResource(
                        newsResource = resource,
                        isBookmarked = resource.id in userData.bookmarkedNewsResources,
                    )
                }
            }
}
```

### KMP Note
Use cases are pure Kotlin, fully portable to KMP commonMain.

---

## 14. Testing Strategy

### Testing Philosophy

**No mocking libraries.** Use test doubles implementing real interfaces.

### Test Doubles

```kotlin
// MutableSharedFlow-based fake
class TestNewsRepository : NewsRepository {
    private val newsFlow = MutableSharedFlow<List<NewsResource>>(
        replay = 1,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    override fun getNewsResources(query: NewsResourceQuery) =
        newsFlow.map { it.filter(query) }

    fun sendNewsResources(resources: List<NewsResource>) {
        newsFlow.tryEmit(resources)
    }
}
```

### MainDispatcherRule

```kotlin
class MainDispatcherRule(
    private val testDispatcher: TestDispatcher = UnconfinedTestDispatcher(),
) : TestWatcher() {
    override fun starting(description: Description) = Dispatchers.setMain(testDispatcher)
    override fun finished(description: Description) = Dispatchers.resetMain()
}

// Usage
class ViewModelTest {
    @get:Rule
    val dispatcherRule = MainDispatcherRule()

    @Test
    fun test() = runTest { ... }
}
```

### ViewModel Testing

```kotlin
class BookmarksViewModelTest {
    @get:Rule
    val dispatcherRule = MainDispatcherRule()

    private val newsRepository = TestNewsRepository()
    private val userDataRepository = TestUserDataRepository()
    private lateinit var viewModel: BookmarksViewModel

    @Before
    fun setup() {
        viewModel = BookmarksViewModel(
            userDataRepository = userDataRepository,
            userNewsResourceRepository = CompositeUserNewsResourceRepository(
                newsRepository, userDataRepository,
            ),
        )
    }

    @Test
    fun stateIsInitiallyLoading() = runTest {
        assertEquals(Loading, viewModel.feedUiState.value)
    }

    @Test
    fun bookmarkedNews_showsInFeed() = runTest {
        backgroundScope.launch(UnconfinedTestDispatcher()) {
            viewModel.feedUiState.collect()
        }

        newsRepository.sendNewsResources(testNewsResources)
        userDataRepository.setNewsResourceBookmarked("1", true)

        val state = viewModel.feedUiState.value
        assertIs<Success>(state)
        assertEquals(1, state.feed.size)
    }
}
```

### UI Testing with Compose

```kotlin
class ForYouScreenTest {
    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun loadingIndicator_whenLoading_isDisplayed() {
        composeTestRule.setContent {
            ForYouScreen(
                feedState = NewsFeedUiState.Loading,
                onTopicClick = {},
            )
        }

        composeTestRule
            .onNodeWithContentDescription("Loading")
            .assertExists()
    }
}
```

### Screenshot Testing

This template configures Google's experimental Compose Preview Screenshot
Testing plugin rather than Roborazzi. Tests use `@PreviewTest` in each
UI-owning module and cover both reusable components and complete stateless
screen states. See [Compose screenshot testing](docs/SCREENSHOT_TESTING.md) for
why and when to add coverage, local update and validation commands, selected
reference regeneration in Android Studio, and report locations. Roborazzi
remains a viable alternative for projects that need its Robolectric-based
features, but it is not configured here.

### Benchmark Testing

```kotlin
@RunWith(AndroidJUnit4ClassRunner::class)
class ScrollForYouFeedBenchmark {
    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    @Test
    fun scrollFeedWithBaselineProfile() = benchmarkRule.measureRepeated(
        packageName = PACKAGE_NAME,
        metrics = listOf(FrameTimingMetric()),
        compilationMode = CompilationMode.Partial(),
        iterations = 10,
        startupMode = StartupMode.WARM,
        setupBlock = { startActivityAndAllowNotifications() },
    ) {
        forYouScrollFeedDownUp()
    }
}
```

### Hilt Testing

```kotlin
@HiltAndroidTest
class NavigationTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeTestRule = createAndroidComposeRule<MainActivity>()

    @Inject
    lateinit var newsRepository: NewsRepository

    @Before
    fun setup() = hiltRule.inject()
}
```

---

## 15. Build Configuration

### Convention Plugins

Centralized build logic in `/build-logic/convention/`:

```kotlin
// AndroidApplicationConventionPlugin.kt
class AndroidApplicationConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) {
        with(target) {
            with(pluginManager) {
                apply("com.android.application")
                // AGP 9 provides built-in Kotlin; do not apply kotlin-android.
                apply("nowinandroid.android.lint")
            }

            extensions.configure<ApplicationExtension> {
                configureKotlinAndroid(this)
                defaultConfig.targetSdk = 37
            }
        }
    }
}
```

### Plugin Registration

```kotlin
// build-logic/convention/build.gradle.kts
gradlePlugin {
    plugins {
        register("androidApplication") {
            id = "nowinandroid.android.application"
            implementationClass = "AndroidApplicationConventionPlugin"
        }
        register("androidFeatureImpl") {
            id = "nowinandroid.android.feature.impl"
            implementationClass = "AndroidFeatureImplConventionPlugin"
        }
        // ... more plugins
    }
}
```

### Usage in Modules

```kotlin
// feature/foryou/impl/build.gradle.kts
plugins {
    alias(libs.plugins.nowinandroid.android.feature.impl)
    alias(libs.plugins.nowinandroid.android.library.compose)
}

dependencies {
    implementation(projects.core.domain)
    implementation(projects.feature.foryou.api)
}
```

### Version Catalog

```toml
# gradle/libs.versions.toml
[versions]
kotlin = "2.4.20"
androidGradlePlugin = "9.4.1"
composeBom = "2026.09.00"
room = "3.0.3"
hilt = "2.60.1"

[libraries]
androidx-compose-bom = { group = "androidx.compose", name = "compose-bom", version.ref = "composeBom" }
room-runtime = { group = "androidx.room3", name = "room3-runtime", version.ref = "room" }
hilt-android = { group = "com.google.dagger", name = "hilt-android", version.ref = "hilt" }

[plugins]
android-application = { id = "com.android.application", version.ref = "androidGradlePlugin" }
compose-compiler = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
kotlin-jvm = { id = "org.jetbrains.kotlin.jvm", version.ref = "kotlin" }
```

### Gradle Properties

```properties
# gradle.properties
# Memory
org.gradle.jvmargs=-Xmx4g -Xms4g -XX:+UseG1GC

# Performance
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.configuration-cache=true

# Disable unused features
android.defaults.buildfeatures.resvalues=false
android.defaults.buildfeatures.shaders=false
```

### Build Flavors

```kotlin
// NiaFlavor.kt
enum class NiaFlavor(val dimension: String, val applicationIdSuffix: String?) {
    demo("contentType", ".demo"),
    prod("contentType", null),
}

fun configureFlavors(extension: ApplicationExtension) {
    extension.apply {
        flavorDimensions += "contentType"
        productFlavors {
            NiaFlavor.entries.forEach { flavor ->
                create(flavor.name) {
                    dimension = flavor.dimension
                    flavor.applicationIdSuffix?.let { suffix ->
                        applicationIdSuffix = suffix
                    }
                }
            }
        }
    }
}
```

---

## 16. Performance Optimization

### Baseline Profiles

```kotlin
// benchmarks/src/main/kotlin/.../StartupBaselineProfile.kt
class StartupBaselineProfile {
    @get:Rule
    val baselineProfileRule = BaselineProfileRule()

    @Test
    fun generate() = baselineProfileRule.collect(
        PACKAGE_NAME,
        includeInStartupProfile = true,
        profileBlock = MacrobenchmarkScope::startActivityAndAllowNotifications,
    )
}
```

```kotlin
// app/build.gradle.kts
baselineProfile {
    automaticGenerationDuringBuild = false  // Generate for release only
    dexLayoutOptimization = true
}
```

### Compose Compiler Configuration

```
// compose_compiler_config.conf
// Mark data models as stable
com.google.samples.apps.nowinandroid.core.model.data.*
java.time.ZoneId
java.time.ZoneOffset
```

```kotlin
// AndroidCompose.kt
extensions.configure<ComposeCompilerGradlePluginExtension> {
    stabilityConfigurationFiles.add(
        rootProject.projectDirectory.file("compose_compiler_config.conf")
    )

    // Optional: enable metrics for debugging
    if (enableMetrics) {
        metricsDestination.set(project.layout.buildDirectory.dir("compose-metrics"))
        reportsDestination.set(project.layout.buildDirectory.dir("compose-reports"))
    }
}
```

### Jank Tracking

```kotlin
@Composable
fun TrackScrollJank(
    scrollableState: ScrollableState,
    stateName: String,
) {
    TrackJank(scrollableState) { metricsHolder ->
        snapshotFlow { scrollableState.isScrollInProgress }.collect { scrolling ->
            metricsHolder.state?.apply {
                if (scrolling) putState(stateName, "Scrolling=true")
                else removeState(stateName)
            }
        }
    }
}

// Usage
TrackScrollJank(scrollableState = lazyListState, stateName = "forYou:feed")
```

### Lazy Initialization

```kotlin
class MainActivity : ComponentActivity() {
    @Inject
    lateinit var lazyStats: dagger.Lazy<JankStats>

    // Accessed only when needed
    private val jankStats by lazy { lazyStats.get() }
}
```

### R8/ProGuard

```
# app/proguard-rules.pro
-repackageclasses
```

```kotlin
// build.gradle.kts
buildTypes {
    release {
        isMinifyEnabled = true
        proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
    }
}
```

---

## 17. Analytics & Monitoring

### Analytics Abstraction

```kotlin
interface AnalyticsHelper {
    fun logEvent(event: AnalyticsEvent)
}

data class AnalyticsEvent(
    val type: String,
    val extras: List<Param> = emptyList(),
) {
    data class Param(val key: String, val value: String)
}
```

### Implementation Variants

```kotlin
// Production - Firebase
@Singleton
internal class FirebaseAnalyticsHelper @Inject constructor(
    private val firebaseAnalytics: FirebaseAnalytics,
) : AnalyticsHelper {
    override fun logEvent(event: AnalyticsEvent) {
        firebaseAnalytics.logEvent(event.type) {
            event.extras.forEach { param(it.key, it.value) }
        }
    }
}

// Demo - Logging
@Singleton
internal class StubAnalyticsHelper @Inject constructor() : AnalyticsHelper {
    override fun logEvent(event: AnalyticsEvent) {
        Log.d("Analytics", "Event: $event")
    }
}
```

### Composition Local Access

```kotlin
val LocalAnalyticsHelper = staticCompositionLocalOf<AnalyticsHelper> {
    NoOpAnalyticsHelper()
}

@Composable
fun TrackScreenViewEvent(screenName: String) {
    val analyticsHelper = LocalAnalyticsHelper.current
    DisposableEffect(Unit) {
        analyticsHelper.logScreenView(screenName)
        onDispose { }
    }
}
```

### Tracing

```kotlin
// Network initialization
private val networkApi = trace("RetrofitNiaNetwork") {
    Retrofit.Builder().build()
}

// Async operations
traceAsync("Sync", 0) {
    topicRepository.sync()
}
```

### Error Handling

```kotlin
private suspend fun <T> suspendRunCatching(block: suspend () -> T): Result<T> = try {
    Result.success(block())
} catch (e: CancellationException) {
    throw e  // Preserve cancellation
} catch (e: Exception) {
    Log.i("suspendRunCatching", "Failed", e)
    Result.failure(e)
}
```

---

## 18. Accessibility

### Material 3 Built-in Support

Material 3 components include accessibility by default:
- Proper touch targets (48dp minimum)
- Content descriptions
- Focus handling
- State announcements

### Semantic Modifiers

```kotlin
@Composable
fun NewsResourceCard(
    newsResource: NewsResource,
    onClick: () -> Unit,
) {
    Card(
        modifier = Modifier
            .semantics {
                contentDescription = "News: ${newsResource.title}"
                onClick { /* handle */ }
            }
    ) { ... }
}
```

### Image Accessibility

```kotlin
@Composable
fun DynamicAsyncImage(
    imageUrl: String,
    contentDescription: String?,  // Required parameter
) {
    Image(
        painter = painter,
        contentDescription = contentDescription,  // For screen readers
    )
}
```

### Component Documentation

```kotlin
/**
 * @param enabled Controls the enabled state. When `false`, this button
 * will not be clickable and will appear disabled to accessibility services.
 */
@Composable
fun NiaButton(
    onClick: () -> Unit,
    enabled: Boolean = true,
)
```

### Accessibility Testing

Screenshot comparison does not replace semantic or accessibility tests. Keep
Compose UI assertions for roles, labels, state descriptions, touch targets, and
interaction alongside the visual suite. Projects choosing Roborazzi as an
alternative can additionally adopt its ATF integration.

---

## 19. CI/CD Pipeline

### GitHub Actions Workflow

The executable workflow is [.github/workflows/ci.yml](.github/workflows/ci.yml).
It uses JDK 21, installs SDK 37 explicitly, validates the Gradle wrapper through
`setup-gradle`, and pins actions to immutable commits. Dependabot updates those pins.

```bash
./gradlew --no-daemon --stacktrace \
  testDebugUnitTest lintDebug assembleDebug \
  :core:database:assembleDebugAndroidTest \
  :feature:tasks:impl:assembleDebugAndroidTest \
  :app:lintRelease :app:assembleRelease
```

Release assembly exercises R8 and resource shrinking without release signing
credentials. Separate jobs execute device tests on an API 35 emulator and validate
screenshots on macOS 15. These are GitHub Actions jobs; the current GitLab remote
does not execute them, and no GitLab pipeline is included.
Projects adding formatting plugins, convention builds, or product flavors should
add their actual task names to this workflow.

### Dependency Guard

Optional extension: this starter does not apply the Dependency Guard plugin or define `prodReleaseRuntimeClasspath`. Configure the plugin and your actual variant before using this example.

```kotlin
// app/build.gradle.kts
dependencyGuard {
    configuration("prodReleaseRuntimeClasspath")
}
```

Fails build if dependencies change unexpectedly. Update baseline:
```bash
./gradlew dependencyGuardBaseline
```

### Screenshot Verification

The GitHub Actions screenshot job validates all three modules on macOS 15, with
UTC and English locale. Run the same `validateDebugScreenshotTest` tasks locally
before review for UI changes; the exact command and rendering limitations are in
[Compose screenshot testing](docs/SCREENSHOT_TESTING.md). Review intentional
reference changes visually. Never update references automatically on a pull request.

### Instrumented Tests

The workflow runs Room and feature tests on an API 35 phone, then runs the
separate-process functional journeys from the existing benchmark module:

```bash
./gradlew :core:database:connectedDebugAndroidTest :feature:tasks:impl:connectedDebugAndroidTest
./gradlew :benchmark:connectedNonMinifiedReleaseAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=app.sroka.benchmark.TasksSmokeTest
```

Use a connected emulator or device locally. Also test the minimum API 26 and
current target API 37 before shipping a product. See [Testing](docs/TESTING.md).

### Baseline Profile Generation

Generation remains explicit and is not a nightly CI job in this starter:

```bash
./gradlew :app:generateBaselineProfile
```

Use an API 33+ device or emulator, inspect the generated rules, and commit them.
Measure startup on a physical device. See [Performance testing](docs/PERFORMANCE_TESTING.md)
for the generation and measurement variants and commands.

---

## 20. Best Practices Summary

### Architecture

| Do | Don't |
|----|-------|
| Use offline-first with local source of truth | Fetch data directly from network for UI |
| Define clear layer boundaries | Mix data and UI concerns |
| Use sealed interfaces for UI state | Use multiple boolean flags |
| Expose Flow from repositories | Expose suspend functions that return data once |
| Use `stateIn` with `WhileSubscribed(5000)` | Use `stateIn(Eagerly)` by default |

### Compose

| Do | Don't |
|----|-------|
| Wrap Material components with app-specific styling | Use Material components directly |
| Separate stateful and stateless composables | Put ViewModel in every composable |
| Use `collectAsStateWithLifecycle()` | Use `collectAsState()` |
| Define multi-preview annotations | Duplicate preview code |
| Use Composition Locals for theming | Pass theme values through all composables |

### Dependency Injection

| Do | Don't |
|----|-------|
| Use constructor injection | Use field injection |
| Mark implementations as `internal` | Expose implementation details |
| Use `@Binds` for interface bindings | Use `@Provides` for simple bindings |
| Use custom dispatcher qualifiers | Use hardcoded `Dispatchers.IO` |
| Use `dagger.Lazy` for expensive initialization | Initialize eagerly on main thread |

### Testing

| Do | Don't |
|----|-------|
| Use test doubles with real interfaces | Use mocking libraries |
| Test state changes, not implementation | Test internal implementation |
| Use `MainDispatcherRule` for coroutines | Forget to reset dispatchers |
| Write screenshot tests for components | Only test business logic |
| Run benchmarks to catch performance regressions | Ship without performance testing |

### Build

| Do | Don't |
|----|-------|
| Use convention plugins for shared config | Duplicate Gradle configuration |
| Use version catalog for dependencies | Define versions in multiple places |
| Enable configuration cache | Use incompatible plugins |
| Generate baseline profiles for release | Ship without AOT optimization |
| Use Gradle Managed Devices for CI | Rely only on real devices |

### Anti-Patterns to Avoid

1. **God ViewModel** - ViewModels with too many responsibilities
2. **Nested Navigation** - Deep navigation hierarchies hard to reason about
3. **Blocking Main Thread** - Network/DB on main thread
4. **Ignoring Lifecycle** - Not handling configuration changes
5. **Over-Engineering** - Creating abstractions before needed
6. **Under-Testing** - Skipping UI and integration tests
7. **Magic Strings** - Hardcoded strings instead of constants
8. **Ignoring Accessibility** - Missing content descriptions

### Decision Guidelines

**When to add Domain Layer:**
- Combining data from 2+ repositories
- Complex business logic
- Logic reused across ViewModels

**When to use Composite Repository:**
- Simple combination without transformation
- Pattern is consistent across the app

**When to split modules:**
- Clear bounded context
- Different teams own different features
- Build times need improvement

**When to use Room vs DataStore:**
- Room: Relational data, complex queries, large datasets
- DataStore: User preferences, small key-value pairs

---

## Appendix: Key File Locations

### Architecture
- `core/data/repository/OfflineFirstNewsRepository.kt` - Repository pattern
- `core/data/SyncUtilities.kt` - Sync algorithm
- `core/domain/GetFollowableTopicsUseCase.kt` - Use case pattern

### UI
- `core/designsystem/theme/Theme.kt` - Theming
- `core/designsystem/component/Button.kt` - Component wrapping
- `feature/foryou/impl/ForYouScreen.kt` - Screen pattern
- `feature/foryou/impl/ForYouViewModel.kt` - ViewModel pattern

### Data
- `core/database/NiaDatabase.kt` - Room setup
- `core/datastore/NiaPreferencesDataSource.kt` - DataStore
- `core/network/retrofit/RetrofitNiaNetwork.kt` - Networking

### Sync
- `sync/work/SyncWorker.kt` - Background sync

### Build
- `build-logic/convention/` - All convention plugins
- `gradle/libs.versions.toml` - Version catalog

### Testing
- `core/testing/util/MainDispatcherRule.kt` - Test utilities
- `core/testing/repository/TestNewsRepository.kt` - Test doubles

---

## Version Information

The architectural examples originated from Now in Android. The executable
starter was reviewed against stable releases on **September 19, 2026**, with
Navigation updated on **October 1, 2026**:

- Kotlin 2.4.20 and AGP built-in Kotlin
- Gradle 9.8.0 and Android Gradle Plugin 9.4.1
- Jetpack Compose BOM 2026.09.00 and Navigation 3 1.2.0
- Room 3.0.3 and Hilt 2.60.1
- Android compile/target SDK 37, min SDK 26

Use [gradle/libs.versions.toml](gradle/libs.versions.toml) as the source of truth
for sources and scope.
