import { useMemo, Suspense } from 'react';
import {
  DescriptionList,
  DescriptionListDescription,
  DescriptionListGroup,
  DescriptionListTerm,
  Grid,
  GridItem,
} from '@patternfly/react-core';
import { useTranslation } from 'react-i18next';
import {
  ConsoleDataView,
  getNameCellProps,
  actionsCellProps,
  nameCellProps,
} from '@console/app/src/components/data-view/ConsoleDataView';
import { useColumnWidthSettings } from '@console/app/src/components/data-view/useResizableColumnProps';
import { LazyActionMenu } from '@console/shared/src/components/actions/LazyActionMenu';
import { ActionMenuVariant } from '@console/shared/src/components/actions/types';
import { Timestamp } from '@console/shared/src/components/datetime/Timestamp';
import PaneBody from '@console/shared/src/components/layout/PaneBody';
import { DASH } from '@console/shared/src/constants/ui';
import { ServiceAccountModel } from '../models';
import { referenceForModel } from '../module/k8s';
import { DetailsPage, ListPage } from './factory';
import { ResourceSummary } from './utils/details-page';
import { SectionHeading } from './utils/headings';
import { navFactory } from './utils/horizontal-nav';
import { ResourceLink } from './utils/resource-link';
import { LoadingBox } from './utils/status-box';

const kind = 'ServiceAccount';
const serviceAccountReference = referenceForModel(ServiceAccountModel);

const tableColumnInfo = [
  { id: 'name' },
  { id: 'namespace' },
  { id: 'secrets' },
  { id: 'created' },
  { id: 'actions' },
];

const getDataViewRows = (data, columns) =>
  data.map(({ obj }) => {
    const {
      metadata: { name, namespace, uid, creationTimestamp },
      secrets,
    } = obj;

    const rowCells = {
      [tableColumnInfo[0].id]: {
        cell: <ResourceLink kind={kind} name={name} namespace={namespace} title={uid} />,
        props: getNameCellProps(name),
      },
      [tableColumnInfo[1].id]: {
        cell: <ResourceLink kind="Namespace" name={namespace} title={namespace} />,
      },
      [tableColumnInfo[2].id]: {
        cell: secrets ? secrets.length : 0,
      },
      [tableColumnInfo[3].id]: {
        cell: <Timestamp timestamp={creationTimestamp} />,
      },
      [tableColumnInfo[4].id]: {
        cell: <LazyActionMenu context={{ [serviceAccountReference]: obj }} />,
        props: actionsCellProps,
      },
    };

    return columns.map(({ id }) => {
      const cell = rowCells[id]?.cell || DASH;
      const props = rowCells[id]?.props || undefined;
      return {
        id,
        props,
        cell,
      };
    });
  });

const SecretRefList = ({ refs, namespace, emptyText }) => {
  if (!refs || refs.length === 0) {
    return <span className="pf-v6-u-color-200">{emptyText}</span>;
  }
  return refs.map(({ name }) => (
    <ResourceLink key={name} kind="Secret" name={name} namespace={namespace} />
  ));
};

const Details = ({ obj: serviceaccount }) => {
  const { t } = useTranslation('public');
  const { imagePullSecrets, secrets } = serviceaccount;
  const { namespace } = serviceaccount.metadata;

  return (
    <PaneBody>
      <SectionHeading text={t('ServiceAccount details')} />
      <Grid hasGutter>
        <GridItem md={6}>
          <ResourceSummary resource={serviceaccount} />
        </GridItem>
        <GridItem md={6}>
          <DescriptionList>
            <DescriptionListGroup>
              <DescriptionListTerm>{t('Image pull secrets')}</DescriptionListTerm>
              <DescriptionListDescription>
                <SecretRefList
                  refs={imagePullSecrets}
                  namespace={namespace}
                  emptyText={t('No image pull secrets')}
                />
              </DescriptionListDescription>
            </DescriptionListGroup>
            <DescriptionListGroup>
              <DescriptionListTerm>{t('Mountable secrets')}</DescriptionListTerm>
              <DescriptionListDescription>
                <SecretRefList
                  refs={secrets}
                  namespace={namespace}
                  emptyText={t('No mountable secrets')}
                />
              </DescriptionListDescription>
            </DescriptionListGroup>
          </DescriptionList>
        </GridItem>
      </Grid>
    </PaneBody>
  );
};

const ServiceAccountsDetailsPage = (props) => (
  <DetailsPage
    {...props}
    kind={serviceAccountReference}
    customActionMenu={(_kindModel, obj) => (
      <LazyActionMenu
        context={{ [serviceAccountReference]: obj }}
        variant={ActionMenuVariant.DROPDOWN}
      />
    )}
    pages={[navFactory.details(Details), navFactory.editYaml()]}
  />
);

const useServiceAccountColumns = () => {
  const { t } = useTranslation('public');
  const { getResizableProps, resetAllColumnWidths } = useColumnWidthSettings(ServiceAccountModel);

  const columns = useMemo(
    () => [
      {
        title: t('Name'),
        id: tableColumnInfo[0].id,
        sort: 'metadata.name',
        resizableProps: getResizableProps(tableColumnInfo[0].id),
        props: {
          ...nameCellProps,
          modifier: 'nowrap',
        },
      },
      {
        title: t('Namespace'),
        id: tableColumnInfo[1].id,
        sort: 'metadata.namespace',
        resizableProps: getResizableProps(tableColumnInfo[1].id),
        props: {
          modifier: 'nowrap',
        },
      },
      {
        title: t('Secrets'),
        id: tableColumnInfo[2].id,
        sort: 'secrets.length',
        resizableProps: getResizableProps(tableColumnInfo[2].id),
        props: {
          modifier: 'nowrap',
        },
      },
      {
        title: t('Created'),
        id: tableColumnInfo[3].id,
        sort: 'metadata.creationTimestamp',
        resizableProps: getResizableProps(tableColumnInfo[3].id),
        props: {
          modifier: 'nowrap',
        },
      },
      {
        title: '',
        id: tableColumnInfo[4].id,
        props: {
          ...actionsCellProps,
        },
      },
    ],
    [t, getResizableProps],
  );

  return { columns, resetAllColumnWidths };
};

const ServiceAccountsList = (props) => {
  const { data, loaded } = props;
  const { t } = useTranslation('public');
  const { columns, resetAllColumnWidths } = useServiceAccountColumns();

  return (
    <Suspense fallback={<LoadingBox />}>
      <ConsoleDataView
        {...props}
        data={data || []}
        loaded={loaded}
        label={t('ServiceAccounts')}
        columns={columns}
        getDataViewRows={getDataViewRows}
        hideColumnManagement
        isResizable
        resetAllColumnWidths={resetAllColumnWidths}
      />
    </Suspense>
  );
};
const ServiceAccountsPage = (props) => (
  <ListPage ListComponent={ServiceAccountsList} {...props} canCreate omitFilterToolbar />
);
export { ServiceAccountsPage, ServiceAccountsDetailsPage };
