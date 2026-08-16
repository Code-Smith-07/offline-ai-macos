<script lang="ts">
	import { models, settings, user } from '$lib/stores';
	import { getContext, onMount } from 'svelte';
	import { toast } from 'svelte-sonner';
	import Selector from './ModelSelector/Selector.svelte';

	import { updateUserSettings } from '$lib/apis/users';
	import { getOllamaLoadedModels, preloadOllamaModel } from '$lib/apis/ollama';
	import equal from 'fast-deep-equal';
	const i18n = getContext('i18n');

	export let selectedModels = [''];
	export let disabled = false;
	export let generationActive = false;

	export let showSetDefault = true;
	export let triggerClassName = 'text-lg';
	export let className = undefined;
	export let placement: 'top' | 'bottom' | 'auto' = 'bottom';
	export let align: 'start' | 'end' = 'start';

	let compareModels = selectedModels.length > 1;
	let runtimeRefreshPending = false;
	let previousGenerationActive = generationActive;
	let runtimeReady = false;
	let runtimeModels: any[] = [];
	let preloadingModelIds: string[] = [];

	const refreshRuntimeModels = async () => {
		if (runtimeRefreshPending || typeof window === 'undefined') return;

		runtimeRefreshPending = true;
		try {
			runtimeModels = await getOllamaLoadedModels(localStorage.token);
			runtimeReady = true;
		} catch {
			// Runtime status is supplementary; chat remains usable if Ollama is reconnecting.
		} finally {
			runtimeRefreshPending = false;
		}
	};

	const preloadSelectedModel = async (event: CustomEvent) => {
		const modelId = event.detail?.value;
		const model = event.detail?.model ?? $models.find((item) => item.id === modelId);
		if (!modelId || model?.owned_by !== 'ollama') return;

		await refreshRuntimeModels();
		if (runtimeModels.some((item) => (item.model ?? item.name) === modelId)) return;
		if (preloadingModelIds.includes(modelId)) return;

		preloadingModelIds = [...preloadingModelIds, modelId];
		try {
			await preloadOllamaModel(localStorage.token, modelId);
			await refreshRuntimeModels();
		} catch (error: any) {
			console.error('Failed to preload Ollama model', error);
			const message =
				error?.detail ?? error?.error ?? error?.message ?? $i18n.t('Failed to load model');
			toast.error(typeof message === 'string' ? message : $i18n.t('Failed to load model'));
		} finally {
			preloadingModelIds = preloadingModelIds.filter((id) => id !== modelId);
			await refreshRuntimeModels();
		}
	};

	onMount(() => {
		refreshRuntimeModels();
		const pollTimer = window.setInterval(refreshRuntimeModels, 2000);
		const handleVisibilityChange = () => {
			if (!document.hidden) refreshRuntimeModels();
		};
		document.addEventListener('visibilitychange', handleVisibilityChange);

		return () => {
			window.clearInterval(pollTimer);
			document.removeEventListener('visibilitychange', handleVisibilityChange);
		};
	});

	const saveDefaultModel = async () => {
		const hasEmptyModel = selectedModels.filter((it) => it === '');
		if (hasEmptyModel.length) {
			toast.error($i18n.t('Choose a model before saving...'));
			return;
		}
		settings.set({ ...$settings, models: selectedModels });
		await updateUserSettings(localStorage.token, { ui: $settings });

		toast.success($i18n.t('Default model updated'));
	};

	const pinModelHandler = async (modelId) => {
		let pinnedModels = $settings?.pinnedModels ?? [];

		if (pinnedModels.includes(modelId)) {
			pinnedModels = pinnedModels.filter((id) => id !== modelId);
		} else {
			pinnedModels = [...new Set([...pinnedModels, modelId])];
		}

		settings.set({ ...$settings, pinnedModels: pinnedModels });
		await updateUserSettings(localStorage.token, { ui: $settings });
	};

	$: if (selectedModels.length > 0 && $models.length > 0) {
		const _selectedModels = selectedModels.map((model) =>
			$models.map((m) => m.id).includes(model) ? model : ''
		);

		if (!equal(_selectedModels, selectedModels)) {
			selectedModels = _selectedModels;
		}
	}

	$: if (selectedModels.length > 1 && !compareModels) {
		compareModels = true;
	}

	$: if (generationActive !== previousGenerationActive) {
		previousGenerationActive = generationActive;
		refreshRuntimeModels();
	}

	$: selectedOllamaModels = selectedModels
		.map((modelId) => $models.find((model) => model.id === modelId))
		.filter((model) => model?.owned_by === 'ollama');
	$: runtimeModelIds = runtimeModels.map((model) => model.model ?? model.name);
	$: activeSelectedModels = selectedOllamaModels.filter((model) =>
		runtimeReady ? runtimeModelIds.includes(model.id) : (model as any).loaded
	);
	$: allSelectedModelsActive =
		selectedOllamaModels.length > 0 && activeSelectedModels.length === selectedOllamaModels.length;
	$: selectedModelPreloading = selectedOllamaModels.some((model) =>
		preloadingModelIds.includes(model.id)
	);
	$: runtimeStatus =
		selectedOllamaModels.length === 0
			? null
			: allSelectedModelsActive
				? {
						label:
							selectedOllamaModels.length === 1
								? $i18n.t('Model active')
								: $i18n.t('{{count}} models active', { count: selectedOllamaModels.length }),
						kind: 'active'
					}
				: generationActive || selectedModelPreloading
					? {
							label:
								selectedOllamaModels.length === 1
									? $i18n.t('Loading model…')
									: $i18n.t('Loading models…'),
							kind: 'loading'
						}
					: activeSelectedModels.length > 0
						? {
								label: $i18n.t('{{active}}/{{total}} models active', {
									active: activeSelectedModels.length,
									total: selectedOllamaModels.length
								}),
								kind: 'active'
							}
						: {
								label:
									selectedOllamaModels.length === 1
										? $i18n.t('Model not loaded')
										: $i18n.t('Models not loaded'),
								kind: 'idle'
							};

	const withRuntimeStatus = (model: any) => {
		if (model.owned_by !== 'ollama' || !runtimeReady) return model;

		const runtimeModel = runtimeModels.find((item) => (item.model ?? item.name) === model.id);
		const expiresAt = runtimeModel?.expires_at
			? Math.floor(new Date(runtimeModel.expires_at).getTime() / 1000)
			: undefined;

		return {
			...model,
			loaded: runtimeModel !== undefined,
			ollama: {
				...(model.ollama ?? {}),
				...(expiresAt !== undefined ? { expires_at: expiresAt } : {})
			}
		};
	};
</script>

<div class="flex min-w-0 max-w-full flex-col items-start">
	<div class="flex min-w-0 max-w-full items-center gap-1.5">
		{#if runtimeStatus}
			<div
				class="flex shrink-0 items-center gap-1 rounded-full px-1.5 py-1 text-[10px] font-medium leading-none {runtimeStatus.kind ===
				'active'
					? 'bg-green-50 text-green-700 dark:bg-green-500/10 dark:text-green-300'
					: runtimeStatus.kind === 'loading'
						? 'bg-amber-50 text-amber-700 dark:bg-amber-500/10 dark:text-amber-300'
						: 'bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400'}"
				aria-live="polite"
				title={runtimeStatus.kind === 'active'
					? $i18n.t('The model is active in memory, so the next response should start faster.')
					: runtimeStatus.kind === 'loading'
						? $i18n.t('The model is being loaded into memory. The first response takes longer.')
					: $i18n.t('Select the model again to load it into memory.')}
			>
				{#if runtimeStatus.kind === 'loading'}
					<span
						class="size-1.5 animate-spin rounded-full border border-current border-t-transparent"
					></span>
				{:else}
					<span
						class="size-1.5 rounded-full {runtimeStatus.kind === 'active'
							? 'bg-green-500'
							: 'bg-gray-400 dark:bg-gray-500'}"
					></span>
				{/if}
				<span>{runtimeStatus.label}</span>
			</div>
		{/if}

		<div class="min-w-0 max-w-full overflow-hidden">
			<div class="min-w-0 max-w-full">
				<Selector
					id="model"
					placeholder={$i18n.t('Select a model')}
					items={$models.map((model) => ({
						value: model.id,
						label: model.name,
						model: withRuntimeStatus(model)
					}))}
					{pinModelHandler}
					{className}
					{triggerClassName}
					{placement}
					{align}
					{showSetDefault}
					onSetDefault={saveDefaultModel}
					multipleEnabled={$user?.role === 'admin' ||
						($user?.permissions?.chat?.multiple_models ?? true)}
					{disabled}
					bind:compareEnabled={compareModels}
					bind:values={selectedModels}
					on:select={preloadSelectedModel}
				/>
			</div>
		</div>
	</div>
</div>
