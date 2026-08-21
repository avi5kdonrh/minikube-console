import type { FC, FormEvent } from 'react';
import { useState, useEffect, useCallback, useMemo } from 'react';
import {
  Button,
  Content,
  ContentVariants,
  Form,
  FormGroup,
  Modal,
  ModalBody,
  ModalHeader,
  ModalVariant,
} from '@patternfly/react-core';
import * as fuzzy from 'fuzzysearch';
import { Trans, useTranslation } from 'react-i18next';
import type { OverlayComponent } from '@console/dynamic-plugin-sdk/src/app/modal-support/OverlayProvider';
import { ModalFooterWithAlerts } from '@console/shared/src/components/modals/ModalFooterWithAlerts';
import { usePromiseHandler } from '@console/shared/src/hooks/usePromiseHandler';
import type { ModalComponentProps } from '@console/shared/src/types/modal';
import { SecretModel, ServiceAccountModel } from '../../models';
import type { K8sResourceCommon, SecretKind } from '../../module/k8s';
import { k8sList, k8sPatch } from '../../module/k8s';
import { ConsoleSelect } from '../utils/console-select';
import { ResourceIcon, ResourceName } from '../utils/resource-icon';

// Secret types that can be used as image pull secrets.
const PULL_SECRET_TYPES = ['kubernetes.io/dockerconfigjson', 'kubernetes.io/dockercfg'];

// K8sResourceKind has no top-level imagePullSecrets, so type the SA explicitly.
type ServiceAccountKind = K8sResourceCommon & {
  imagePullSecrets?: { name: string }[];
  secrets?: { name: string }[];
};

interface LinkPullSecretModalProps extends ModalComponentProps {
  serviceAccount: ServiceAccountKind;
}

const LinkPullSecretModal: FC<LinkPullSecretModalProps> = (props) => {
  const { serviceAccount, cancel, close } = props;
  const { t } = useTranslation('public');
  const [handlePromise, inProgress, errorMessage] = usePromiseHandler();

  const { namespace } = serviceAccount.metadata;
  const [secrets, setSecrets] = useState<SecretKind[]>([]);
  const [selectedSecret, setSelectedSecret] = useState('');

  // Names already linked as image pull secrets on this ServiceAccount.
  const linked = useMemo(
    () => new Set((serviceAccount.imagePullSecrets || []).map((ref) => ref.name)),
    [serviceAccount],
  );

  useEffect(() => {
    k8sList(SecretModel, { ns: namespace })
      .then((res: SecretKind[]) =>
        setSecrets(
          res.filter((s) => PULL_SECRET_TYPES.includes(s.type) && !linked.has(s.metadata.name)),
        ),
      )
      .catch(() => setSecrets([]));
  }, [namespace, linked]);

  const secretOptions = useMemo(
    () =>
      secrets.reduce(
        (acc, secret) => {
          acc[secret.metadata.name] = <ResourceName kind="Secret" name={secret.metadata.name} />;
          return acc;
        },
        {} as { [name: string]: JSX.Element },
      ),
    [secrets],
  );

  const autocompleteFilter = (text: string, item) => fuzzy(text, item.props.name);

  const submit = useCallback(
    (event: FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      if (!selectedSecret) {
        return;
      }
      // Create the array if it doesn't exist; append otherwise.
      const patch = serviceAccount.imagePullSecrets?.length
        ? [{ op: 'add' as const, path: '/imagePullSecrets/-', value: { name: selectedSecret } }]
        : [{ op: 'add' as const, path: '/imagePullSecrets', value: [{ name: selectedSecret }] }];

      handlePromise(k8sPatch(ServiceAccountModel, serviceAccount, patch))
        .then(close)
        .catch(() => {});
    },
    [selectedSecret, serviceAccount, handlePromise, close],
  );

  const saName = serviceAccount.metadata.name;
  const noSecrets = secrets.length === 0;

  return (
    <>
      <ModalHeader title={t('Link pull secret')} labelId="link-pull-secret-modal-title" />
      <ModalBody>
        <Content component={ContentVariants.p}>
          <Trans t={t} ns="public">
            Link an image pull secret to <ResourceIcon kind="ServiceAccount" />
            {{ saName }} so that Pods using this ServiceAccount can pull images from private
            registries.
          </Trans>
        </Content>
        <Form id="link-pull-secret-form" onSubmit={submit}>
          <FormGroup label={t('Pull secret')} isRequired fieldId="link-pull-secret__secret">
            {noSecrets ? (
              <Content component={ContentVariants.p}>
                {t(
                  'There are no unlinked pull secrets in this namespace. Create a pull secret first from the Secrets page.',
                )}
              </Content>
            ) : (
              <ConsoleSelect
                items={secretOptions}
                selectedKey={selectedSecret}
                title={t('Select a pull secret')}
                onChange={setSelectedSecret}
                autocompleteFilter={autocompleteFilter}
                autocompletePlaceholder={t('Select a pull secret')}
                id="link-pull-secret__secret"
                dataTest="link-pull-secret-dropdown"
              />
            )}
          </FormGroup>
        </Form>
      </ModalBody>
      <ModalFooterWithAlerts errorMessage={errorMessage}>
        <Button
          type="submit"
          variant="primary"
          isLoading={inProgress}
          isDisabled={inProgress || noSecrets || !selectedSecret}
          data-test="confirm-action"
          form="link-pull-secret-form"
        >
          {t('Save')}
        </Button>
        <Button
          variant="link"
          onClick={cancel}
          data-test="modal-cancel-action"
          data-test-id="modal-cancel-action"
        >
          {t('Cancel')}
        </Button>
      </ModalFooterWithAlerts>
    </>
  );
};

export const LinkPullSecretModalOverlay: OverlayComponent<LinkPullSecretModalProps> = (props) => {
  const [isOpen, setIsOpen] = useState(true);
  const handleClose = () => {
    setIsOpen(false);
    props.closeOverlay();
  };

  return isOpen ? (
    <Modal
      variant={ModalVariant.small}
      isOpen
      onClose={handleClose}
      aria-labelledby="link-pull-secret-modal-title"
    >
      <LinkPullSecretModal {...props} cancel={handleClose} close={handleClose} />
    </Modal>
  ) : null;
};
