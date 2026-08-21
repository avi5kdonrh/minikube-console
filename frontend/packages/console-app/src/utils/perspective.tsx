import { RhUiGearGroupFillIcon } from '@patternfly/react-icons';
import type { Perspective, ResolvedExtension } from '@console/dynamic-plugin-sdk';
import { FLAGS } from '@console/shared/src/constants/common';

export const icon: ResolvedExtension<Perspective>['properties']['icon'] = {
  default: RhUiGearGroupFillIcon,
};

export const getLandingPageURL: ResolvedExtension<Perspective>['properties']['landingPageURL'] = (
  flags,
) => {
  if (!flags[FLAGS.OPENSHIFT]) {
    return '/search';
  }
  if (flags[FLAGS.CAN_LIST_NS] && flags[FLAGS.MONITORING]) {
    return '/dashboards';
  }
  // The Project API (project.openshift.io) is only served by the OpenShift apiserver; on a
  // cluster without it (e.g. plain Kubernetes) fall back to the Namespaces list instead.
  return flags.OPENSHIFT_PROJECT ? '/k8s/cluster/projects' : '/k8s/cluster/namespaces';
};

export const getImportRedirectURL: ResolvedExtension<Perspective>['properties']['importRedirectURL'] =
  (namespace) => `/topology/ns/${namespace}`;
