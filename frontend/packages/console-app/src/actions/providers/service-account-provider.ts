import { useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import type { Action } from '@console/dynamic-plugin-sdk';
import { useOverlay } from '@console/dynamic-plugin-sdk/src/app/modal-support/useOverlay';
import { LazyLinkPullSecretModalOverlay } from '@console/internal/components/modals';
import { asAccessReview } from '@console/internal/components/utils/rbac';
import type { K8sResourceKind } from '@console/internal/module/k8s';
import { referenceFor } from '@console/internal/module/k8s';
import { useK8sModel } from '@console/shared/src/hooks/useK8sModel';
import { useCommonResourceActions } from '../hooks/useCommonResourceActions';

export const useServiceAccountActionsProvider = (resource: K8sResourceKind) => {
  const { t } = useTranslation('console-app');
  const [kindObj, inFlight] = useK8sModel(referenceFor(resource));
  const launchModal = useOverlay();

  const commonActions = useCommonResourceActions(kindObj, resource);

  const actions = useMemo<Action[]>(
    () => [
      {
        id: 'link-pull-secret',
        label: t('Link pull secret'),
        cta: () => launchModal(LazyLinkPullSecretModalOverlay, { serviceAccount: resource }),
        accessReview: kindObj && asAccessReview(kindObj, resource, 'patch'),
      },
      ...commonActions,
    ],
    [t, launchModal, resource, kindObj, commonActions],
  );

  return [actions, !inFlight, undefined];
};
